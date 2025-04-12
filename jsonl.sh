#!/bin/bash

# 使用相对路径
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SILLY_TAVERN_DIR="${SCRIPT_DIR}/SillyTavern"
SOURCE_DIR="${SILLY_TAVERN_DIR}/data/default-user/chats"
SAVE_BASE_DIR="${SCRIPT_DIR}/saved-date/default-user/chats"
LOG_DIR="${SCRIPT_DIR}/saved-date"
LOG_FILE="${LOG_DIR}/line_counts.log"
CONFIG_FILE="${LOG_DIR}/config.conf"
RULES_FILE="${LOG_DIR}/rules.txt"

# GitHub相关设置
GH_FAST="https://ghfast.top/"
GITHUB_REPO="Liu-fucheng/Jsonl_monitor"
GH_DOWNLOAD_URL_BASE="https://github.com/${GITHUB_REPO}/raw/main"

# 默认配置
SAVE_INTERVAL=20
SAVE_MODE="interval" # "interval" 或 "latest"
ROLLBACK_MODE=1 # 1: 删除重写仅保留最新档, 2: 保留旧档并标记
SORT_METHOD="name" # "name" 或 "time"
SORT_ORDER="asc" # "asc" 或 "desc"

# 确保目录存在
mkdir -p "$SOURCE_DIR"
mkdir -p "$SAVE_BASE_DIR"
mkdir -p "$LOG_DIR"

# 记录文件行数、修改时间和减少标记的关联数组
declare -A line_counts
declare -A mod_times
declare -A line_reduced     #, 1记录行数减少的文件
declare -A processed_floors # 记录已处理的楼层

# 初始扫描模式标志 - 用于区分初始扫描和正常监控
INITIAL_SCAN=0

# 全局规则数组
declare -a GLOBAL_RULES
# 角色局部规则
declare -A CHAR_RULES
# 聊天记录局部规则
declare -A CHAT_RULES

# 检查依赖项，不需要jq了
check_dependencies() {
    # 不再需要检查jq
    return 0
}

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        # 创建默认配置
        echo "SAVE_INTERVAL=$SAVE_INTERVAL" > "$CONFIG_FILE"
        echo "SAVE_MODE=$SAVE_MODE" >> "$CONFIG_FILE"
        echo "ROLLBACK_MODE=$ROLLBACK_MODE" >> "$CONFIG_FILE"
        echo "SORT_METHOD=$SORT_METHOD" >> "$CONFIG_FILE"
        echo "SORT_ORDER=$SORT_ORDER" >> "$CONFIG_FILE"
    fi
}

# 保存配置
save_config() {
    echo "SAVE_INTERVAL=$SAVE_INTERVAL" > "$CONFIG_FILE"
    echo "SAVE_MODE=$SAVE_MODE" >> "$CONFIG_FILE"
    echo "ROLLBACK_MODE=$ROLLBACK_MODE" >> "$CONFIG_FILE"
    echo "SORT_METHOD=$SORT_METHOD" >> "$CONFIG_FILE"
    echo "SORT_ORDER=$SORT_ORDER" >> "$CONFIG_FILE"
}

# 加载规则 - 使用简单的文本格式
load_rules() {
    GLOBAL_RULES=()
    CHAR_RULES=()
    CHAT_RULES=()
    
    if [ -f "$RULES_FILE" ]; then
        while IFS='|' read -r rule_type target rule_data; do
            if [ "$rule_type" = "global" ]; then
                GLOBAL_RULES+=("$rule_data")
            elif [ "$rule_type" = "char" ]; then
                CHAR_RULES["$target"]="$rule_data"
            elif [ "$rule_type" = "chat" ]; then
                CHAT_RULES["$target"]="$rule_data"
            fi
        done < "$RULES_FILE"
    else
        # 创建空规则文件
        touch "$RULES_FILE"
    fi
}

# 保存规则 - 使用简单的文本格式
save_rules() {
    > "$RULES_FILE"  # 清空文件
    
    # 保存全局规则
    for rule in "${GLOBAL_RULES[@]}"; do
        # 确保规则格式正确
        read -r rule_type params <<< $(parse_rule "$rule")
        if [[ "$rule" != *":"* ]]; then
            # 如果规则不包含冒号，则添加冒号
            rule="${rule_type}:${params}"
        fi
        echo "global||$rule" >> "$RULES_FILE"
    done
    
    # 保存角色规则
    for char_name in "${!CHAR_RULES[@]}"; do
        local rule="${CHAR_RULES[$char_name]}"
        # 确保规则格式正确
        read -r rule_type params <<< $(parse_rule "$rule")
        if [[ "$rule" != *":"* ]]; then
            # 如果规则不包含冒号，则添加冒号
            rule="${rule_type}:${params}"
        fi
        echo "char|$char_name|$rule" >> "$RULES_FILE"
    done
    
    # 保存聊天规则
    for chat_path in "${!CHAT_RULES[@]}"; do
        local rule="${CHAT_RULES[$chat_path]}"
        # 确保规则格式正确
        read -r rule_type params <<< $(parse_rule "$rule")
        if [[ "$rule" != *":"* ]]; then
            # 如果规则不包含冒号，则添加冒号
            rule="${rule_type}:${params}"
        fi
        echo "chat|$chat_path|$rule" >> "$RULES_FILE"
    done
}

# 从日志文件加载行数记录
load_line_counts() {
    line_counts=()
    line_reduced=()
    
    if [ -f "$LOG_FILE" ]; then
        while IFS='|' read -r file count reduced; do
            if [ -n "$file" ] && [ -n "$count" ]; then
                line_counts["$file"]=$count
                if [ "$reduced" = "1" ]; then
                    line_reduced["$file"]=1
                fi
            fi
        done < "$LOG_FILE"
    else
        touch "$LOG_FILE"
    fi
}

# 保存行数记录到日志文件
save_line_counts() {
    > "$LOG_FILE"  # 清空日志文件
    for file in "${!line_counts[@]}"; do
        reduced=${line_reduced[$file]:-0}
        echo "$file|${line_counts[$file]}|$reduced" >> "$LOG_FILE"
    done
}

# 比较文件内容函数
compare_file_contents() {
    local file1="$1"
    local file2="$2"
    
    # 比较两个文件的内容
    cmp -s "$file1" "$file2"
    return $?  # 0表示内容相同，非0表示内容不同
}

# 添加回退日志条目
add_rollback_log_entry() {
    local chat_dir="$1"
    local prev_floor="$2"
    local new_floor="$3"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 确保日志目录存在
    mkdir -p "$chat_dir"
    
    # 回退日志文件路径
    local rollback_log="$chat_dir/rollback_log.txt"
    
    # 添加日志条目 (仅追加，不修改或删除)
    echo "[$timestamp] 回退记录: 从 ${prev_floor}楼 回退到 ${new_floor}楼" >> "$rollback_log"
    echo "已记录回退事件到日志: $rollback_log"
}

# 获取不重复的文件名（改进版）
get_unique_filename() {
    local base_name="$1"
    local extension="$2"
    local floor_number="$3"  # 楼层号
    local content="$4"      # 文件内容
    local dir_path="$(dirname "$base_name")"
    
    # 基础文件名
    local base_file="${base_name}.${extension}"
    
    # 先检查是否存在同名同楼层的文件
    if [ -f "$base_file" ]; then
        # 存在同名文件，比对内容
        local existing_content=$(cat "$base_file")
        if [ "$existing_content" = "$content" ]; then
            # 内容相同，直接返回现有文件名
            echo "$base_file"
            return
        fi
    fi
    
    # 内容不同或文件不存在，查找可用文件名
    local output_file="$base_file"
    local counter=1
    
    while [ -f "$output_file" ]; do
        output_file="${base_name}(${counter}).${extension}"
        # 如果存在已编号的文件，也比对内容
        if [ -f "$output_file" ]; then
            local existing_content=$(cat "$output_file")
            if [ "$existing_content" = "$content" ]; then
                # 内容相同，返回现有文件名
                echo "$output_file"
                return
            fi
        fi
        counter=$((counter + 1))
    done
    
    # 记录此楼层已处理
    local key="${dir_path}_${floor_number}"
    processed_floors["$key"]="$output_file"
    
    echo "$output_file"
}

# 解析规则字符串 - 简单文本格式
parse_rule() {
    local rule="$1"
    
    # 直接包含"interval_above:"或"latest_above:"的规则
    if [[ "$rule" == interval_above:* ]]; then
        local rule_type="interval_above"
        local params="${rule#interval_above:}"
        echo "$rule_type $params"
        return
    elif [[ "$rule" == latest_above:* ]]; then
        local rule_type="latest_above"
        local params="${rule#latest_above:}"
        echo "$rule_type $params"
        return
    fi
    
    # 检查是否为"type params"格式
    if [[ "$rule" == interval_above* ]] && [[ "$rule" != *":"* ]]; then
        local params="${rule#interval_above }"
        echo "interval_above $params"
        return
    elif [[ "$rule" == latest_above* ]] && [[ "$rule" != *":"* ]]; then
        local params="${rule#latest_above }"
        echo "latest_above $params"
        return
    fi
    
    # 尝试标准解析（格式: type:参数）
    local rule_type="${rule%%:*}"
    local params="${rule#*:}"
    
    # 如果解析失败，尝试空格分隔
    if [ "$rule_type" = "$rule" ]; then
        rule_type=$(echo "$rule" | cut -d' ' -f1)
        params=$(echo "$rule" | cut -d' ' -f2-)
    fi
    
    echo "$rule_type $params"
}

# 决定是否保存此楼层（基于规则）
should_save_floor() {
    local floor="$1"
    local latest_floor="$2"
    local chat_dir="$3"
    
    # 最新楼层始终保存
    if [ "$floor" -eq "$latest_floor" ]; then
        return 0
    fi
    
    # 获取角色名和聊天记录ID
    local rel_path="${chat_dir#$SAVE_BASE_DIR/}"
    local char_name=$(echo "$rel_path" | cut -d'/' -f1)
    local chat_id=$(echo "$rel_path" | cut -d'/' -f2)
    
    # 首先检查是否有"只保留最高楼层"规则适用
    local latest_only_rule_found=0
    
    # 检查全局规则中的"只保留最高楼层"规则
    for rule in "${GLOBAL_RULES[@]}"; do
        read -r rule_type params <<< $(parse_rule "$rule")
        if [ "$rule_type" = "latest_above" ] && [ "$floor" -ge "$params" ]; then
            # 如果是"只保留最高楼层"规则且适用于当前楼层
            # 只有最高楼层才保留
            if [ "$floor" -eq "$latest_floor" ]; then
                return 0
            else
                return 1
            fi
        fi
    done
    
    # 检查角色规则中的"只保留最高楼层"规则
    if [ -n "${CHAR_RULES[$char_name]}" ]; then
        local rule="${CHAR_RULES[$char_name]}"
        read -r rule_type params <<< $(parse_rule "$rule")
        if [ "$rule_type" = "latest_above" ] && [ "$floor" -ge "$params" ]; then
            if [ "$floor" -eq "$latest_floor" ]; then
                return 0
            else
                return 1
            fi
        fi
    fi
    
    # 检查聊天记录规则中的"只保留最高楼层"规则
    if [ -n "${CHAT_RULES["$char_name/$chat_id"]}" ]; then
        local rule="${CHAT_RULES["$char_name/$chat_id"]}"
        read -r rule_type params <<< $(parse_rule "$rule")
        if [ "$rule_type" = "latest_above" ] && [ "$floor" -ge "$params" ]; then
            if [ "$floor" -eq "$latest_floor" ]; then
                return 0
            else
                return 1
            fi
        fi
    fi
    
    # 如果没有"只保留最高楼层"规则适用，再检查其他规则
    
    # 检查是否有适用的聊天记录规则
    if [ -n "${CHAT_RULES["$char_name/$chat_id"]}" ]; then
        local rule="${CHAT_RULES["$char_name/$chat_id"]}"
        if apply_rule "$floor" "$latest_floor" "$rule"; then
            return 0
        fi
    fi
    
    # 检查是否有适用的角色规则
    if [ -n "${CHAR_RULES["$char_name"]}" ]; then
        local rule="${CHAR_RULES["$char_name"]}"
        if apply_rule "$floor" "$latest_floor" "$rule"; then
            return 0
        fi
    fi
    
    # 检查是否有适用的全局规则
    for rule in "${GLOBAL_RULES[@]}"; do
        read -r rule_type _ <<< $(parse_rule "$rule")
        # 跳过已处理的"只保留最高楼层"规则
        if [ "$rule_type" != "latest_above" ] && apply_rule "$floor" "$latest_floor" "$rule"; then
            return 0
        fi
    done
    
    # 默认规则
    if [ "$SAVE_MODE" = "latest" ]; then
        # 仅保存最新楼层
        return 1
    else
        # 保存1楼和从1开始的倍数楼层
        if [ "$floor" -eq 1 ] || [ $(( floor % SAVE_INTERVAL )) -eq 1 ]; then
            return 0
        else
            return 1
        fi
    fi
}

# 应用规则 - 使用简单文本格式
apply_rule() {
    local floor="$1"
    local latest_floor="$2"
    local rule="$3"
    
    # 解析规则类型和参数
    read -r rule_type params <<< $(parse_rule "$rule")
    
    if [ "$rule_type" = "interval_above" ]; then
        # 格式: interval_above:min_floor,range,interval
        IFS=',' read -ra args <<< "$params"
        local min_floor="${args[0]}"
        local range="${args[1]}"
        local interval="${args[2]}"
        
        if [ "$floor" -ge "$min_floor" ]; then
            # 如果在保存范围内
            if [ "$((latest_floor - floor))" -le "$range" ]; then
                # 检查是否是倍数 (确保从1开始: 1,1+interval,1+2*interval...)
                if [ "$floor" -eq 1 ] || [ $(( (floor - 1) % interval )) -eq 0 ]; then
                    return 0
                fi
            fi
            return 1
        fi
    elif [ "$rule_type" = "latest_above" ]; then
        # 格式: latest_above:min_floor
        local min_floor="$params"
        
        if [ "$floor" -ge "$min_floor" ]; then
            # 只保留最新楼层
            if [ "$floor" -eq "$latest_floor" ]; then
                return 0
            fi
            return 1
        fi
    fi
    
    # 不适用此规则
    return 2
}

# 检查文件行数变化
check_line_count_changes() {
    local file="$1"
    
    # 获取当前行数
    local current_count=$(wc -l < "$file")
    local previous_count=${line_counts["$file"]:-0}
    
    # 如果是初始扫描，只记录行数，不处理变化
    if [ "$INITIAL_SCAN" -eq 1 ]; then
        if [ "$current_count" -ne "$previous_count" ]; then
            line_counts["$file"]=$current_count
            return 0
        fi
        return 1
    fi
    
    # 正常监控模式下处理变化
    # 如果行数变化
    if [ "$current_count" -ne "$previous_count" ]; then
        echo "检测到行数变化: $file ($previous_count -> $current_count)"
        process_changes "$file" "$previous_count" "$current_count"
        line_counts["$file"]=$current_count
        return 0
    fi
    
    # 行数相同，检查内容是否变化（仅在非初始扫描时）
    if check_file_changes "$file"; then
        # 文件有修改但行数相同，也处理变化
        echo "检测到文件修改但行数相同: $file"
        process_content_changes "$file" "$current_count"
        return 0
    fi
    
    return 1  # 没有变化
}
# 获取不重复的xz文件名（基于内容和楼层）
get_xz_unique_filename() {
    local base_name="$1"
    local floor_number="$2"  # 楼层号
    local content="$3"      # 文件内容
    local dir_path="$(dirname "$base_name")"
    
    # 基础文件名 (xz格式)
    local base_file="${base_name}.xz"
    
    # 先检查是否存在同名同楼层的xz文件
    if [ -f "$base_file" ]; then
        # 存在同名文件，比对内容
        local existing_content=$(xz -dc "$base_file" 2>/dev/null)
        if [ "$existing_content" = "$content" ]; then
            # 内容相同，直接返回现有文件名
            echo "$base_file"
            return
        fi
    fi
    
    # 内容不同或文件不存在，查找可用文件名
    local output_file="$base_file"
    local counter=1
    
    while [ -f "$output_file" ]; do
        output_file="${base_name}(${counter}).xz"
        # 如果存在已编号的文件，也比对内容
        if [ -f "$output_file" ]; then
            local existing_content=$(xz -dc "$output_file" 2>/dev/null)
            if [ "$existing_content" = "$content" ]; then
                # 内容相同，返回现有文件名
                echo "$output_file"
                return
            fi
        fi
        counter=$((counter + 1))
    done
    
    # 记录此楼层已处理
    local key="${dir_path}_${floor_number}"
    processed_floors["$key"]="$output_file"
    
    echo "$output_file"
}

# 处理内容变化但行数相同的情况
process_content_changes() {
    local file="$1"
    local current_count="$2"
    
    # 获取相对路径和文件名
    local rel_path="${file#$SOURCE_DIR/}"
    local dir_name=$(dirname "$rel_path")
    local file_name=$(basename "$rel_path" .jsonl)
    
    # 创建目标目录
    local target_dir="$SAVE_BASE_DIR/$dir_name/$file_name"
    mkdir -p "$target_dir"
    
    # 计算楼层数 (行数)
    local floor=$((current_count))
    
    # 获取当前文件内容
    local content=$(cat "$file")
    
    # 检查是否安装了xz
    if ! command -v xz &> /dev/null; then
        echo "未安装xz工具，正在尝试安装..."
        # 尝试使用不同的包管理器安装xz
        if command -v apt &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y xz-utils
        elif command -v yum &> /dev/null; then
            sudo yum install -y xz
        elif command -v pacman &> /dev/null; then
            sudo pacman -S --noconfirm xz
        elif command -v pkg &> /dev/null; then
            pkg install -y xz
        elif command -v brew &> /dev/null; then
            brew install xz
        else
            echo "无法自动安装xz工具，请手动安装后重试。"
            press_any_key
            return 1
        fi
        
        # 再次检查是否安装成功
        if ! command -v xz &> /dev/null; then
            echo "安装xz工具失败，将使用原始jsonl格式保存。"
        fi
    fi
    
    # 首先检查.xz格式的文件
    for existing_file in "$target_dir/${floor}楼"*.xz; do
        [ -f "$existing_file" ] || continue
        
        # 比较内容
        local existing_content=$(xz -dc "$existing_file" 2>/dev/null)
        if [ "$existing_content" != "$content" ]; then
            # 内容不同，用新内容替换旧文件
            echo "$content" | xz -c > "$existing_file"
            echo "更新同楼层但内容不同的xz文件: $existing_file"
            return 0
        else
            # 内容相同，不需要更新
            echo "存在同楼层且内容相同的xz文件: $existing_file，无需更新"
            return 0
        fi
    done
    
    # 然后检查旧的.jsonl文件（如果存在的话）
    for existing_file in "$target_dir/${floor}楼"*.jsonl; do
        [ -f "$existing_file" ] || continue
        
        # 比较内容
        compare_file_contents <(echo "$content") "$existing_file"
        if [ $? -ne 0 ]; then
            # 内容不同，用新内容替换旧文件，并转换为.xz格式
            local xz_file="${existing_file%.jsonl}.xz"
            echo "$content" | xz -c > "$xz_file"
            echo "将jsonl文件转换为xz格式并更新: $xz_file"
            rm "$existing_file"  # 删除旧的jsonl文件
            return 0
        else
            # 内容相同，转换为.xz格式
            local xz_file="${existing_file%.jsonl}.xz"
            echo "$content" | xz -c > "$xz_file"
            echo "将相同内容的jsonl文件转换为xz格式: $xz_file"
            rm "$existing_file"  # 删除旧的jsonl文件
            return 0
        fi
    done
    
    # 如果没有找到同楼层文件，且应该保存此楼层，则创建新文件
    if should_save_floor "$floor" "$floor" "$target_dir"; then
        # 准备保存文件名
        local base_save_name="${target_dir}/${floor}楼"
        
        # 如果xz可用，使用xz格式保存
        if command -v xz &> /dev/null; then
            # 获取唯一文件名，同时传入文件内容进行比对
            local save_file=$(get_xz_unique_filename "$base_save_name" "$floor" "$content")
            
            # 检查返回的文件是否已存在
            if [ -f "$save_file" ]; then
                echo "文件内容已存在，跳过创建: $save_file"
            else
                # 压缩并保存文件
                echo "$content" | xz -c > "$save_file"
                echo "已保存整个文件到: $save_file"
            fi
        else
            # xz不可用，回退到jsonl格式
            local save_file=$(get_unique_filename "$base_save_name" "jsonl" "$floor" "$content")
            
            # 检查返回的文件是否已存在
            if [ -f "$save_file" ]; then
                echo "文件内容已存在，跳过创建: $save_file"
            else
                # 保存整个文件
                echo "$content" > "$save_file"
                echo "已保存整个文件到: $save_file"
            fi
        fi
    fi
}

# 处理文件变化
process_changes() {
    local file="$1"
    local previous_count="$2"
    local current_count="$3"
    
    # 获取相对路径和文件名
    local rel_path="${file#$SOURCE_DIR/}"
    local dir_name=$(dirname "$rel_path")
    local file_name=$(basename "$rel_path" .jsonl)
    
    # 创建目标目录
    local target_dir="$SAVE_BASE_DIR/$dir_name/$file_name"
    mkdir -p "$target_dir"
    
    # 计算楼层数 (行数)
    local floor=$((current_count))
    
    # 检测行数是否减少
    if [ "$current_count" -lt "$previous_count" ]; then
        echo "检测到行数减少: $file ($previous_count -> $current_count)，可能发生了删除或回退"
        # 标记文件行数减少
        line_reduced["$file"]=1
        # 不处理减少的情况，直接返回
        return
    fi
    
    # 在生成新文件前，找出当前文件夹中修改时间最新的文件
    local previous_latest_file=""
    local latest_mtime=0
    
    # 同时检查.jsonl和.xz文件
    for existing_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
        [ -f "$existing_file" ] || continue
        
        # 获取文件修改时间
        local mtime=$(stat -c %Y "$existing_file" 2>/dev/null || stat -f %m "$existing_file" 2>/dev/null)
        
        # 更新最新文件
        if [ "$mtime" -gt "$latest_mtime" ]; then
            latest_mtime=$mtime
            previous_latest_file="$existing_file"
        fi
    done
    
    # 检测是否在减少后又增加 (回退)
    local is_rollback=0
    if [ "${line_reduced[$file]:-0}" -eq 1 ]; then
        echo "检测到行数在减少后又增加: $file，确认为回退"
        is_rollback=1
        
        # 获取最新档的楼层数
        local prev_floor=0
        if [ -n "$previous_latest_file" ]; then
            prev_floor=$(echo "$previous_latest_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        fi
        
        # 记录回退事件
        add_rollback_log_entry "$target_dir" "$prev_floor" "$floor"
        
        # 清除回退标记
        line_reduced["$file"]=0
    fi
    
    # 如果是回退，根据回退模式处理
    if [ "$is_rollback" -eq 1 ]; then
        if [ "$ROLLBACK_MODE" -eq 1 ]; then
            # 模式1: 删除重写仅保留最新档
            echo "使用回退模式1: 删除重写仅保留最新档"
            
            # 查找并删除之前的所有楼层文件（包括_old标记的文件）
            for old_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
                [ -f "$old_file" ] || continue
                rm "$old_file"
                echo "删除之前的楼层文件: $old_file"
            done
            
        else
            # 模式2: 保留旧档并标记
            echo "使用回退模式2: 保留旧档并标记"
            
            # 找到最新的楼层文件并标记为_old
            local max_floor=0
            local max_file=""
            
            for old_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
                [ -f "$old_file" ] || continue
                
                # 已经有_old标记的文件跳过
                if [[ "$old_file" == *"_old"* ]]; then
                    continue
                fi
                
                # 提取楼层数
                old_floor=$(echo "$old_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
                
                if [ -n "$old_floor" ] && [ "$old_floor" -gt "$max_floor" ]; then
                    max_floor=$old_floor
                    max_file="$old_file"
                fi
            done

# 模式2: 保留旧档并标记
echo "使用回退模式2: 保留旧档并标记"

# 找到最新的楼层文件并标记为_old
local max_floor=0
local max_file=""

# 修改：同时检查 jsonl 和 xz 文件
for old_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
    [ -f "$old_file" ] || continue
    
    # 已经有_old标记的文件跳过
    if [[ "$old_file" == *"_old"* ]]; then
        continue
    fi
    
    # 提取楼层数
    old_floor=$(echo "$old_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
    
    if [ -n "$old_floor" ] && [ "$old_floor" -gt "$max_floor" ]; then
        max_floor=$old_floor
        max_file="$old_file"
    fi
done

# 重命名最新的楼层文件
if [ -n "$max_file" ]; then
    # 确定文件扩展名和基础名
    local file_ext=""
    if [[ "$max_file" == *.jsonl ]]; then
        file_ext="jsonl"
    elif [[ "$max_file" == *.xz ]]; then
        file_ext="xz"
    fi
    
    local old_basename=$(basename "$max_file" .$file_ext)
    local new_name="${target_dir}/${old_basename}_old"
    
                # 获取文件内容用于比对
                local content=""
                if [[ "$file_ext" == "jsonl" ]]; then
                    content=$(cat "$max_file")
                else
                    content=$(xz -dc "$max_file" 2>/dev/null)
                fi
                
                local new_file=$(get_unique_filename "$new_name" "$file_ext" "${old_basename}_old" "$content")
                
                # 如果返回的文件名存在且内容相同，说明已存在相同内容
                if [ "$new_file" != "$max_file" ] && [ -f "$new_file" ]; then
                    # 文件已存在且内容相同，删除旧文件
                    rm "$max_file"
                    echo "删除重复文件: $max_file (内容已存在于 $new_file)"
                else
                    # 文件不存在或内容不同，重命名
                    mv "$max_file" "$new_file"
                    echo "将之前的最新楼层标记为: $new_file"
                fi
            fi
        fi
    fi
    
    # 决定是否保存当前楼层
    if should_save_floor "$floor" "$floor" "$target_dir"; then
        # 准备保存文件名
        local base_save_name="${target_dir}/${floor}楼"
        
        # 获取要保存的内容
        local content=$(cat "$file")
        
        # 检查是否有同行数但不同内容的文件需要更新
        local found_matching_file=0
        
        # 首先检查xz格式文件
        for existing_file in "$target_dir/${floor}楼"*.xz; do
            [ -f "$existing_file" ] || continue
            
            # 解压并比较内容
            local existing_content=$(xz -dc "$existing_file" 2>/dev/null)
            if [ "$existing_content" != "$content" ]; then
                # 内容不同，用新内容替换旧文件
                echo "$content" | xz -c > "$existing_file"
                echo "更新同楼层但内容不同的xz文件: $existing_file"
                found_matching_file=1
                break
            else
                # 内容相同，不需要更新
                echo "存在同楼层且内容相同的xz文件: $existing_file，无需更新"
                found_matching_file=1
                break
            fi
        done
        
        # 如果没有找到xz格式文件，再检查jsonl格式文件
        if [ $found_matching_file -eq 0 ]; then
            for existing_file in "$target_dir/${floor}楼"*.jsonl; do
                [ -f "$existing_file" ] || continue
                
                # 比较内容
                compare_file_contents <(echo "$content") "$existing_file"
                if [ $? -ne 0 ]; then
                    # 内容不同，用新内容替换旧文件，并转换为xz格式
                    if command -v xz &> /dev/null; then
                        local xz_file="${existing_file%.jsonl}.xz"
                        echo "$content" | xz -c > "$xz_file"
                        echo "将不同内容的jsonl文件更新并转换为xz格式: $xz_file"
                        rm "$existing_file"  # 删除旧的jsonl文件
                    else
                        # xz不可用，仍使用jsonl格式更新
                        echo "$content" > "$existing_file"
                        echo "更新同楼层但内容不同的jsonl文件: $existing_file"
                    fi
                    found_matching_file=1
                    break
                else
                    # 内容相同，尝试转换为xz格式
                    if command -v xz &> /dev/null; then
                        local xz_file="${existing_file%.jsonl}.xz"
                        echo "$content" | xz -c > "$xz_file"
                        echo "将相同内容的jsonl文件转换为xz格式: $xz_file"
                        rm "$existing_file"  # 删除旧的jsonl文件
                    else
                        # xz不可用，保留jsonl格式
                        echo "存在同楼层且内容相同的jsonl文件: $existing_file，无需更新"
                    fi
                    found_matching_file=1
                    break
                fi
            done
        fi
        
        # 如果没有找到同楼层文件，创建新文件
        if [ $found_matching_file -eq 0 ]; then
            # 检查是否安装了xz
            if command -v xz &> /dev/null; then
                # 获取唯一文件名，同时传入文件内容进行比对（使用xz专用函数）
                local save_file=$(get_xz_unique_filename "$base_save_name" "$floor" "$content")
                
                # 检查返回的文件是否已存在
                if [ -f "$save_file" ]; then
                    echo "文件内容已存在，跳过创建: $save_file"
                else
                    # 保存压缩文件
                    echo "$content" | xz -c > "$save_file"
                    echo "已保存整个文件到: $save_file (xz格式)"
                fi
            else
                # xz不可用，回退到jsonl格式
                local save_file=$(get_unique_filename "$base_save_name" "jsonl" "$floor" "$content")
                
                # 检查返回的文件是否已存在
                if [ -f "$save_file" ]; then
                    echo "文件内容已存在，跳过创建: $save_file"
                else
                    # 保存整个文件
                    echo "$content" > "$save_file"
                    echo "已保存整个文件到: $save_file (jsonl格式)"
                fi
            fi
        fi
        
        # 如果不是回退，且之前记录了最新的文件，且该文件不是应该保留的楼层，则删除它
        if [ "$is_rollback" -eq 0 ] && [ -n "$previous_latest_file" ] && [ -f "$previous_latest_file" ]; then
            # 检查文件是否带有_old标记，如果有则跳过删除
            if [[ "$previous_latest_file" == *"_old"* ]]; then
                echo "保留带有_old标记的文件: $previous_latest_file"
            else
                # 提取楼层数
                local prev_floor=$(echo "$previous_latest_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
                
                if [ -n "$prev_floor" ] && ! should_save_floor "$prev_floor" "$floor" "$target_dir"; then
                    rm "$previous_latest_file"
                    echo "删除前一个最新文件: $previous_latest_file"
                fi
            fi
        fi
    fi
}

# 检查文件修改时间
check_file_changes() {
    local file="$1"
    
    # 检查文件是否存在
    if [ ! -f "$file" ]; then
        return 1
    fi
    
    # 获取文件修改时间
    local mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
    local old_mtime=${mod_times["$file"]:-0}
    
    # 如果修改时间变了，返回true
    if [ "$mtime" != "$old_mtime" ]; then
        mod_times["$file"]=$mtime
        return 0
    fi
    
    return 1
}

# 初始扫描 - 仅记录文件信息，不处理变化
initial_scan() {
    echo "执行初始扫描..."
    
    # 设置初始扫描标志
    INITIAL_SCAN=1
    
    # 获取所有JSONL文件
    mapfile -t jsonl_files < <(find "$SOURCE_DIR" -type f -name "*.jsonl")
    
    for file in "${jsonl_files[@]}"; do
        # 记录文件行数
        count=$(wc -l < "$file")
        line_counts["$file"]=$count
        # 记录文件修改时间
        mod_times["$file"]=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
        
        # 比对日志与存档文件夹的最新楼层
        compare_log_with_archives "$file" "$count"
    done
    
    # 保存记录
    save_line_counts
    
    # 关闭初始扫描标志
    INITIAL_SCAN=0
    
    echo "初始扫描完成，记录了 ${#line_counts[@]} 个文件"
}

# 比对日志楼层与存档文件夹最新楼层
compare_log_with_archives() {
    local file="$1"
    local log_floor="$2"  # 日志中记录的楼层数
    
    # 获取相对路径和文件名
    local rel_path="${file#$SOURCE_DIR/}"
    local dir_name=$(dirname "$rel_path")
    local file_name=$(basename "$rel_path" .jsonl)
    
    # 目标目录
    local target_dir="$SAVE_BASE_DIR/$dir_name/$file_name"
    mkdir -p "$target_dir"
    
    # 找到存档文件夹中的最新楼层
    local max_floor=0
    local max_file=""
    
    # 检查jsonl和xz文件
    for archive_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
        [ -f "$archive_file" ] || continue
        
        # 排除带有_old标记的文件
        if [[ "$archive_file" == *"_old"* ]]; then
            continue
        fi
        
        # 提取楼层数
        local archive_floor=$(echo "$archive_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$archive_floor" ] && [ "$archive_floor" -gt "$max_floor" ]; then
            max_floor=$archive_floor
            max_file="$archive_file"
        fi
    done
    
    # 如果日志楼层与存档最新楼层不一致，进行处理
    if [ "$max_floor" -ne "$log_floor" ]; then
        echo "检测到楼层不匹配: $file"
        echo "  - 日志楼层: $log_floor"
        echo "  - 存档最新楼层: $max_floor"
        
        # 情况1: 日志楼层高于存档最新楼层
        if [ "$log_floor" -gt "$max_floor" ]; then
            echo "日志楼层高于存档最新楼层，执行普通新生成"
            # 获取当前文件内容
            local content=$(cat "$file")
            
            # 保存文件
            if should_save_floor "$log_floor" "$log_floor" "$target_dir"; then
                local base_save_name="${target_dir}/${log_floor}楼"
                
                # 如果支持xz压缩
                if command -v xz &> /dev/null; then
                    local save_file=$(get_xz_unique_filename "$base_save_name" "$log_floor" "$content")
                    
                    if [ ! -f "$save_file" ]; then
                        echo "$content" | xz -c > "$save_file"
                        echo "已保存日志楼层文件: $save_file"
                    fi
                else
                    local save_file=$(get_unique_filename "$base_save_name" "jsonl" "$log_floor" "$content")
                    
                    if [ ! -f "$save_file" ]; then
                        echo "$content" > "$save_file"
                        echo "已保存日志楼层文件: $save_file"
                    fi
                fi
                
                # 判断存档文件夹楼层是否符合保留规则
                if ! should_save_floor "$max_floor" "$log_floor" "$target_dir"; then
                    # 删除不符合保留规则的存档文件
                    for old_file in "$target_dir/${max_floor}楼"*.jsonl "$target_dir/${max_floor}楼"*.xz; do
                        [ -f "$old_file" ] || continue
                        if [[ "$old_file" != *"_old"* ]]; then
                            rm "$old_file"
                            echo "删除不符合保留规则的存档文件: $old_file"
                        fi
                    done
                else
                    echo "存档文件夹楼层符合保留规则，保留文件"
                fi
            fi
        # 情况2: 存档最新楼层高于日志楼层，且日志楼层非0
        elif [ "$max_floor" -gt "$log_floor" ] && [ "$log_floor" -ne 0 ]; then
            echo "存档最新楼层高于日志楼层，可能发生过回退"
            
            # 询问是否保留存档文件夹最新楼层
            echo "是否保留存档文件夹最新楼层 $max_floor？ (y/n)"
            read -n 1 keep_max_floor
            echo ""
            
            if [[ "$keep_max_floor" =~ ^[Yy]$ ]]; then
                # 将最新楼层文件标记为_old
                if [ -n "$max_file" ]; then
                    # 确定文件扩展名
                    local file_ext=""
                    if [[ "$max_file" == *.jsonl ]]; then
                        file_ext="jsonl"
                    elif [[ "$max_file" == *.xz ]]; then
                        file_ext="xz"
                    fi
                    
                    local old_basename=$(basename "$max_file" .$file_ext)
                    local new_name="${target_dir}/${old_basename}_old"
                    
                    # 获取文件内容用于比对
                    local content=""
                    if [[ "$file_ext" == "jsonl" ]]; then
                        content=$(cat "$max_file")
                    else
                        content=$(xz -dc "$max_file" 2>/dev/null)
                    fi
                    
                    local new_file=$(get_unique_filename "$new_name" "$file_ext" "${old_basename}_old" "$content")
                    
                    # 如果返回的文件名存在且内容相同，说明已存在相同内容
                    if [ "$new_file" != "$max_file" ] && [ -f "$new_file" ]; then
                        # 文件已存在且内容相同，删除旧文件
                        rm "$max_file"
                        echo "删除重复文件: $max_file (内容已存在于 $new_file)"
                    else
                        # 文件不存在或内容不同，重命名
                        mv "$max_file" "$new_file"
                        echo "将存档最新楼层标记为: $new_file"
                    fi
                fi
                
                # 生成日志楼层
                local content=$(cat "$file")
                
                if should_save_floor "$log_floor" "$log_floor" "$target_dir"; then
                    local base_save_name="${target_dir}/${log_floor}楼"
                    
                    # 如果支持xz压缩
                    if command -v xz &> /dev/null; then
                        local save_file=$(get_xz_unique_filename "$base_save_name" "$log_floor" "$content")
                        
                        if [ ! -f "$save_file" ]; then
                            echo "$content" | xz -c > "$save_file"
                            echo "已保存日志楼层文件: $save_file"
                        fi
                    else
                        local save_file=$(get_unique_filename "$base_save_name" "jsonl" "$log_floor" "$content")
                        
                        if [ ! -f "$save_file" ]; then
                            echo "$content" > "$save_file"
                            echo "已保存日志楼层文件: $save_file"
                        fi
                    fi
                fi
            else
                # 不保留，执行普通新生成，删除旧的楼层文件
                for old_file in "$target_dir/${max_floor}楼"*.jsonl "$target_dir/${max_floor}楼"*.xz; do
                    [ -f "$old_file" ] || continue
                    if [[ "$old_file" != *"_old"* ]]; then
                        rm "$old_file"
                        echo "删除旧的楼层文件: $old_file"
                    fi
                done
                
                # 生成日志楼层
                local content=$(cat "$file")
                
                if should_save_floor "$log_floor" "$log_floor" "$target_dir"; then
                    local base_save_name="${target_dir}/${log_floor}楼"
                    
                    # 如果支持xz压缩
                    if command -v xz &> /dev/null; then
                        local save_file=$(get_xz_unique_filename "$base_save_name" "$log_floor" "$content")
                        
                        if [ ! -f "$save_file" ]; then
                            echo "$content" | xz -c > "$save_file"
                            echo "已保存日志楼层文件: $save_file"
                        fi
                    else
                        local save_file=$(get_unique_filename "$base_save_name" "jsonl" "$log_floor" "$content")
                        
                        if [ ! -f "$save_file" ]; then
                            echo "$content" > "$save_file"
                            echo "已保存日志楼层文件: $save_file"
                        fi
                    fi
                    
                    # 检查是否因符合保留规则而保留
                    if should_save_floor "$log_floor" "$log_floor" "$target_dir"; then
                        echo "提示: 因符合保留规则，文件 $save_file 被保留"
                    fi
                fi
            fi
        # 情况3: 日志楼层为0，可能是新导入的聊天记录
        elif [ "$log_floor" -eq 0 ] && [ "$max_floor" -gt 0 ]; then
            echo "日志楼层为0，存档文件夹有内容，可能需要导入到酒馆"
            
            # 询问是否需要导入存档到酒馆
            echo "是否需要导入存档到酒馆？ (y/n)"
            read -n 1 import_to_tavern
            echo ""
            
            if [[ "$import_to_tavern" =~ ^[Yy]$ ]]; then
                # 询问导入的楼层类型
                echo "导入哪种楼层？"
                echo "1. 最新楼层 ($max_floor)"
                echo "2. 最高楼层 (可能是其他备份)"
                read -n 1 floor_choice
                echo ""
                
                local import_floor=$max_floor
                
                if [ "$floor_choice" == "2" ]; then
                    # 查找最高楼层文件
                    local highest_floor=0
                    local highest_file=""
                    
                    # 包括带有_old标记的文件
                    for archive_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
                        [ -f "$archive_file" ] || continue
                        
                        # 提取楼层数
                        local archive_floor=$(echo "$archive_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
                        
                        if [ -n "$archive_floor" ] && [ "$archive_floor" -gt "$highest_floor" ]; then
                            highest_floor=$archive_floor
                            highest_file="$archive_file"
                        fi
                    done
                    
                    import_floor=$highest_floor
                    max_file=$highest_file
                fi
                
                # 询问是覆盖还是新建
                echo "请选择导入方式："
                echo "1. 覆盖现有文件"
                echo "2. 创建新文件"
                read -n 1 import_mode
                echo ""
                
                # 获取要导入的文件内容
                local import_content=""
                if [[ "$max_file" == *.jsonl ]]; then
                    import_content=$(cat "$max_file")
                else
                    import_content=$(xz -dc "$max_file" 2>/dev/null)
                fi
                
                if [ "$import_mode" == "1" ]; then
                    # 覆盖现有文件
                    echo "$import_content" > "$file"
                    line_counts["$file"]=$import_floor
                    echo "已将楼层 $import_floor 的内容导入到酒馆，覆盖现有文件"
                else
                    # 创建新文件
                    local new_file_base=$(dirname "$file")/$(basename "$file" .jsonl)
                    local new_file="${new_file_base}_imported.jsonl"
                    local counter=1
                    
                    # 确保文件名不重复
                    while [ -f "$new_file" ]; do
                        new_file="${new_file_base}_imported_${counter}.jsonl"
                        ((counter++))
                    done
                    
                    echo "$import_content" > "$new_file"
                    line_counts["$new_file"]=$import_floor
                    echo "已将楼层 $import_floor 的内容导入到酒馆，创建新文件: $new_file"
                fi
            fi
        fi
    else
        echo "日志楼层与存档最新楼层一致: $log_floor"
    fi
}

# 智能扫描 - 只扫描最近有变化的文件和新文件
smart_scan() {
    local changed_files=0
    
    # 获取所有JSONL文件
    mapfile -t jsonl_files < <(find "$SOURCE_DIR" -type f -name "*.jsonl")
    
    for file in "${jsonl_files[@]}"; do
        # 检查是否为新文件
        if [ -z "${line_counts[$file]}" ]; then
            # 新文件直接添加到记录中
            count=$(wc -l < "$file")
            line_counts["$file"]=$count
            mod_times["$file"]=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
            changed_files=$((changed_files + 1))
            continue
        fi
        
        # 检查行数变化
        if check_line_count_changes "$file"; then
            changed_files=$((changed_files + 1))
        fi
    done
    
    # 如果有变化，保存记录
    if [ $changed_files -gt 0 ]; then
        save_line_counts
    fi
    
    return $changed_files
}

# 存档全部聊天记录
archive_all_chats() {
    clear
    echo "开始扫描..."
    
    # 检查是否安装了xz
    if ! command -v xz &> /dev/null; then
        echo "未安装xz工具，正在尝试安装..."
        # 尝试使用不同的包管理器安装xz
        if command -v apt &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y xz-utils
        elif command -v yum &> /dev/null; then
            sudo yum install -y xz
        elif command -v pacman &> /dev/null; then
            sudo pacman -S --noconfirm xz
        elif command -v pkg &> /dev/null; then
            pkg install -y xz
        elif command -v brew &> /dev/null; then
            brew install xz
        else
            echo "无法自动安装xz工具，请手动安装后重试。"
            press_any_key
            return 1
        fi
        
        # 再次检查是否安装成功
        if ! command -v xz &> /dev/null; then
            echo "安装xz工具失败，无法继续操作。"
            press_any_key
            return 1
        fi
        echo "xz工具安装成功，继续处理..."
    fi
    
    # 获取所有JSONL文件
    mapfile -t jsonl_files < <(find "$SOURCE_DIR" -type f -name "*.jsonl")
    
    total_files=${#jsonl_files[@]}
    processed=0
    
    # 设置一个标记，表示只处理一次，不监控
    INITIAL_SCAN=0
    
    for file in "${jsonl_files[@]}"; do
        # 获取文件行数
        current_count=$(wc -l < "$file")
        
        # 获取相对路径和文件名
        rel_path="${file#$SOURCE_DIR/}"
        dir_name=$(dirname "$rel_path")
        file_name=$(basename "$rel_path" .jsonl)
        
        # 创建目标目录
        target_dir="$SAVE_BASE_DIR/$dir_name/$file_name"
        mkdir -p "$target_dir"
        
        # 计算楼层数 (行数)
        floor=$((current_count))
        
        # 检查目标目录中是否已有该楼层的文件（检查.jsonl和.xz格式）
        found=0
        for existing_file in "$target_dir/${floor}楼"*.jsonl "$target_dir/${floor}楼"*.xz; do
            if [ -f "$existing_file" ]; then
                found=1
                break
            fi
        done
        
        # 如果已有该楼层的文件，则跳过
        if [ $found -eq 1 ]; then
            processed=$((processed + 1))
            continue
        fi
        
        # 获取文件内容
        content=$(cat "$file")
        
        # 保存文件
        if should_save_floor "$floor" "$floor" "$target_dir"; then
            # 准备保存文件名（改为.xz格式）
            base_save_name="${target_dir}/${floor}楼"
            
            # 获取唯一文件名，同时传入文件内容进行比对（使用xz专用函数）
            save_file=$(get_xz_unique_filename "$base_save_name" "$floor" "$content")
            
            # 保存文件内容（直接压缩保存为.xz文件）
            if [ ! -f "$save_file" ]; then
                echo "$content" | xz -c > "$save_file"
                echo "已保存 $save_file"
            fi
        fi
        
        processed=$((processed + 1))
    done
    
    echo "全部存档完成！"
    press_any_key
}

# 获取文件夹最新修改时间（基于内部文件）
get_dir_latest_mtime() {
    local dir="$1"
    local latest_mtime=0
    
    # 查找目录中的所有文件
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            # 获取文件修改时间
            local mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
            
            # 更新最新修改时间
            if [ "$mtime" -gt "$latest_mtime" ]; then
                latest_mtime=$mtime
            fi
        fi
    done < <(find "$dir" -type f)
    
    echo "$latest_mtime"
}

# 排序目录函数 - 返回排序后的目录列表
sort_directories() {
    local dirs=("$@")
    local sorted_dirs=()
    local method="$SORT_METHOD"
    local order="$SORT_ORDER"
    local english_dirs=()
    local chinese_dirs=()
    local dir_times=()
    local dir_names=()
    
    # 如果是按修改时间排序
    if [ "$method" = "time" ]; then
        # 收集目录及其最新修改时间
        for dir in "${dirs[@]}"; do
            local mtime=$(get_dir_latest_mtime "$dir")
            dir_times+=("$mtime|$dir")
        done
        
        # 按时间排序
        if [ "$order" = "asc" ]; then
            # 从旧到新排序
            IFS=$'\n' sorted_dirs=($(sort -t '|' -k1,1n <<<"${dir_times[*]}"))
        else
            # 从新到旧排序
            IFS=$'\n' sorted_dirs=($(sort -t '|' -k1,1nr <<<"${dir_times[*]}"))
        fi
        
        # 提取目录名
        for i in "${!sorted_dirs[@]}"; do
            sorted_dirs[$i]="${sorted_dirs[$i]#*|}"
        done
    else
        # 按名称排序 - 分离英文和中文目录
        for dir in "${dirs[@]}"; do
            local base_name=$(basename "$dir")
            
            # 检查第一个字符是否是英文字母
            if [[ "$base_name" =~ ^[A-Za-z] ]]; then
                english_dirs+=("$dir")
            else
                chinese_dirs+=("$dir")
            fi
        done
        
        # 排序英文目录
        if [ "$order" = "asc" ]; then
            # 按字母升序排序
            IFS=$'\n' english_dirs=($(sort <<<"${english_dirs[*]}"))
            IFS=$'\n' chinese_dirs=($(sort <<<"${chinese_dirs[*]}"))
        else
            # 按字母降序排序
            IFS=$'\n' english_dirs=($(sort -r <<<"${english_dirs[*]}"))
            IFS=$'\n' chinese_dirs=($(sort -r <<<"${chinese_dirs[*]}"))
        fi
        
        # 合并排序后的目录，英文在前，中文在后
        sorted_dirs=("${english_dirs[@]}" "${chinese_dirs[@]}")
    fi
    
    # 返回排序后的目录，使用NULL分隔符防止空格问题
    printf "%s\0" "${sorted_dirs[@]}"
}

# 处理范围选择，转换为选择列表
process_range_selection() {
    local input="$1"
    local max_items="$2"
    local selected=()
    
    # 替换中文逗号为英文逗号
    input=${input//，/,}
    # 替换空格为逗号
    input=${input// /,}
    
    # 如果是全选
    if [ "$input" = "全选" ]; then
        for ((i=1; i<=max_items; i++)); do
            selected+=($i)
        done
        echo "${selected[@]}"
        return
    fi
    
    # 按逗号分割输入
    IFS=',' read -ra parts <<< "$input"
    
    for part in "${parts[@]}"; do
        if [[ $part =~ ^[0-9]+-[0-9]+$ ]]; then
            # 处理范围，如 1-3
            start=${part%-*}
            end=${part#*-}
            if [ "$start" -le "$end" ]; then
                for ((i=start; i<=end; i++)); do
                    if [ "$i" -le "$max_items" ] && [ "$i" -gt 0 ]; then
                        selected+=($i)
                    fi
                done
            fi
        elif [[ $part =~ ^[0-9]+$ ]]; then
            # 处理单个序号
            if [ "$part" -le "$max_items" ] && [ "$part" -gt 0 ]; then
                selected+=($part)
            fi
        fi
    done
    
    # 返回去重后的选择列表
    echo $(printf "%s\n" "${selected[@]}" | sort -nu)
}

# 询问排序方式 - 使用单字符输入
ask_sort_method() {
    echo "请选择排序方式:"
    echo "1. 按名称排序 (英文在前，中文在后; 按s切换升/降序)"
    echo "2. 按修改时间排序 (按s切换新旧顺序)"
    echo -n "请选择 [1/2]: "
    
    local choice=$(get_single_key)
    echo "$choice"
    
    case "$choice" in
        1)
            SORT_METHOD="name"
            ;;
        2)
            SORT_METHOD="time"
            ;;
        s|S)
            # 切换排序顺序
            if [ "$SORT_ORDER" = "asc" ]; then
                SORT_ORDER="desc"
            else
                SORT_ORDER="asc"
            fi
            ;;
        *)
            echo "使用默认排序方式: 按名称排序"
            SORT_METHOD="name"
            ;;
    esac
    
    # 确认当前排序方式
    local method_desc="按名称排序"
    local order_desc="升序"
    
    if [ "$SORT_METHOD" = "time" ]; then
        method_desc="按修改时间排序"
    fi
    
    if [ "$SORT_ORDER" = "desc" ]; then
        order_desc="降序"
    fi
    
    echo "当前排序方式: $method_desc ($order_desc)"
    echo "按 's' 可以切换升/降序"
    echo ""
    
    # 保存配置
    save_config
}

# 找出目录中的最小和最大楼层
get_floor_range() {
    local dir="$1"
    local min_floor=999999
    local max_floor=0
    
    # 找出所有楼层文件(包括jsonl和xz格式)
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$floor" ]; then
            # 更新最小楼层
            if [ "$floor" -lt "$min_floor" ]; then
                min_floor=$floor
            fi
            
            # 更新最大楼层
            if [ "$floor" -gt "$max_floor" ]; then
                max_floor=$floor
            fi
        fi
    done
    
    # 如果没有找到楼层文件
    if [ "$min_floor" -eq 999999 ]; then
        min_floor=0
        max_floor=0
    fi
    
    echo "$min_floor $max_floor"
}

# 计算目录中文件数量
count_files_in_dir() {
    local dir="$1"
    local count=0
    
    # 查找并计数所有jsonl和xz文件
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        count=$((count + 1))
    done
    
    echo "$count"
}

# 检查目录中在指定楼层范围内的文件数量
count_files_in_range() {
    local dir="$1"
    local start_floor="$2"
    local end_floor="$3"
    local latest_floor="$4"
    
    local file_count=0
    local total_files=0
    
    # 计算在范围内的文件数量
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        total_files=$((total_files + 1))
        
        if [ -n "$floor" ] && [ "$floor" -ge "$start_floor" ] && [ "$floor" -le "$end_floor" ]; then
            # 检查是否应该保留
            if ! should_save_floor "$floor" "$latest_floor" "$dir"; then
                file_count=$((file_count + 1))
            fi
        fi
    done
    
    # 返回范围内可删除的文件数和总文件数
    echo "$file_count $total_files"
}

# 检查目录是否可能被完全清空
will_dir_be_empty() {
    local dir="$1"
    local start_floor="$2"
    local end_floor="$3"
    
    # 找出最新楼层
    local latest_floor=0
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$floor" ] && [ "$floor" -gt "$latest_floor" ]; then
            latest_floor=$floor
        fi
    done
    
    # 获取可删除的文件数和总文件数
    read file_count total_files < <(count_files_in_range "$dir" "$start_floor" "$end_floor" "$latest_floor")
    
    # 判断是否所有文件都会被删除
    if [ "$file_count" -eq "$total_files" ]; then
        echo "1" # 目录会被清空
    else
        echo "0" # 目录不会被清空
    fi
}

# 检查目录是否会被保留特定倍数楼层的清理操作清空
will_dir_be_empty_by_multiple() {
    local dir="$1"
    local multiple="$2"
    
    # 找出最新楼层
    local latest_floor=0
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$floor" ]; then
            total_files=$((total_files + 1))
            
            # 修改规则：保留1楼，最新楼层，以及floor % multiple == 1的楼层
            if [ "$floor" -ne "$latest_floor" ] && [ "$floor" -ne 1 ] && [ $(( floor % multiple )) -ne 1 ]; then
                files_to_delete=$((files_to_delete + 1))
            fi
        fi
    done
    
    # 如果会删除所有文件，或者仅剩下最新楼层
    if [ "$files_to_delete" -eq "$total_files" ] || [ "$files_to_delete" -eq "$((total_files - 1))" ]; then
        echo "1" # 目录会被清空或几乎清空
    else
        echo "0" # 目录不会被清空
    fi
}

# 删除指定的聊天目录
delete_chat_dir() {
    local dir="$1"
    
    echo "删除聊天目录: $dir"
    rm -rf "$dir"
}

# 清理所有聊天的冗余存档
cleanup_all_chats() {
    echo "准备清理所有冗余存档..."
    echo "注意：这将根据设置清理所有聊天记录中的非必要楼层。"
    echo -n "输入【确认】后按回车，开始清理操作（输入其他字符或直接换行则取消）: "
    
    read -r confirm
    
    if [ "$confirm" != "确认" ]; then
        echo "操作已取消"
        press_any_key
        return
    fi
    
    echo "开始清理所有冗余存档..."
    
    # 询问楼层范围
    echo -n "请输入要清理的楼层范围(如 \"10\" 或 \"5-20\"，输入\"全选\"表示全部楼层): "
    read -r floor_range
    
    # 解析楼层范围
    start_floor=0
    end_floor=0
    
    if [[ "$floor_range" =~ ^[0-9]+$ ]]; then
        # 单一楼层
        start_floor=$floor_range
        end_floor=$floor_range
    elif [[ "$floor_range" =~ ^[0-9]+-[0-9]+$ ]]; then
        # 楼层范围
        start_floor=${floor_range%-*}
        end_floor=${floor_range#*-}
    elif [ "$floor_range" = "全选" ]; then
        # 全部楼层
        start_floor=-999
        end_floor=-999
    else
        echo "无效的楼层范围，操作已取消"
        press_any_key
        return
    fi
    
    # 先收集所有只有单个文件的目录信息（仅收集符合楼层范围的）
    single_file_dirs=()
    single_file_paths=()
    
    echo "先处理多文件目录..."
    
    # 遍历所有保存的目录
    while IFS= read -r chat_dir; do
        # 获取当前目录的楼层范围
        read dir_min dir_max < <(get_floor_range "$chat_dir")
        
        # 确定实际清理的楼层范围
        local actual_start=$start_floor
        local actual_end=$end_floor
        
        if [ "$actual_start" -eq -999 ]; then
            actual_start=$dir_min
        fi
        
        if [ "$actual_end" -eq -999 ]; then
            actual_end=$dir_max
        fi
        
        # 检查楼层范围是否有效
        if [ "$actual_start" -gt "$actual_end" ] && [ "$actual_start" -ne 0 ] && [ "$actual_end" -ne 0 ]; then
            echo "跳过目录 $chat_dir (无效的楼层范围: $actual_start-$actual_end)"
            continue
        fi
        
        # 目录中的文件总数
        local total_files=$(count_files_in_dir "$chat_dir")
        
        # 如果目录为空，跳过
        if [ "$total_files" -eq 0 ]; then
            continue
        fi
        
        # 如果目录只有一个文件，检查楼层是否在范围内
        if [ "$total_files" -eq 1 ]; then
            # 获取这个唯一文件的路径
            local single_file=""
            for file in "$chat_dir"/*楼*.jsonl; do
                [ -f "$file" ] || continue
                single_file="$file"
                break
            done
            
            if [ -n "$single_file" ]; then
                # 提取楼层数
                floor=$(echo "$single_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
                
                # 检查楼层是否在范围内
                if [ -n "$floor" ] && [ "$floor" -ge "$actual_start" ] && [ "$floor" -le "$actual_end" ]; then
                    single_file_dirs+=("$chat_dir")
                    single_file_paths+=("$single_file")
                fi
            fi
            continue
        fi
        
        # 检查目录是否可能被完全清空
        will_empty=$(will_dir_be_empty "$chat_dir" "$actual_start" "$actual_end")
        if [ "$will_empty" -eq 1 ]; then
            empty_dirs+=("$chat_dir")
            echo "警告：目录 $(basename "$(dirname "$chat_dir")")/$(basename "$chat_dir") 可能会被清空"
        else
            # 正常处理多文件目录
            direct_cleanup_range "$chat_dir" "$actual_start" "$actual_end"
        fi
    done < <(find "${SCRIPT_DIR}/saved-date" -type d -name "*" | grep -v "/.git/")
    
    # 处理可能被清空的目录
    if [ ${#empty_dirs[@]} -gt 0 ]; then
        echo ""
        echo "以下目录在清理后可能会被完全清空："
        for i in "${!empty_dirs[@]}"; do
            echo "$((i+1)). $(basename "$(dirname "${empty_dirs[$i]}")")/$(basename "${empty_dirs[$i]}")"
        done
        
        echo ""
        echo "请选择操作："
        echo "1. 全部删除这些目录"
        echo "2. 删除部分目录（指定范围或序号）"
        echo "3. 保留这些目录（只清理部分文件）"
        echo "4. 取消操作"
        echo -n "选择操作(1-4): "
        read -r choice
        
        case "$choice" in
            1)
                # 全部删除
                echo "即将删除所有可能被清空的目录"
                echo -n "确认删除? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    for dir in "${empty_dirs[@]}"; do
                        delete_chat_dir "$dir"
                    done
                    echo "已删除所有指定目录"
                else
                    echo "取消删除操作"
                    # 仍然执行清理
                    for dir in "${empty_dirs[@]}"; do
                        direct_cleanup_range "$dir" "$actual_start" "$actual_end"
                    done
                    echo "已清理文件但保留目录"
                fi
                ;;
            2)
                # 删除部分目录
                echo "请指定要删除的目录："
                echo "可以输入："
                echo "- 序号范围（如 1-3）"
                echo "- 逗号分隔的序号（如 1,3,5）"
                echo "- 混合使用（如 1-3,5,7-9）"
                echo "- 输入'全选'删除所有目录"
                echo -n "输入要删除的目录: "
                read -r range
                
                # 处理选择
                selected_indices=($(process_range_selection "$range" ${#empty_dirs[@]}))
                
                if [ ${#selected_indices[@]} -eq 0 ]; then
                    echo "未选择任何有效目录，取消删除操作"
                    # 仍然执行清理
                    for dir in "${empty_dirs[@]}"; do
                        direct_cleanup_range "$dir" "$actual_start" "$actual_end"
                    done
                else
                    # 获取要删除的目录
                    to_delete=()
                    for idx in "${selected_indices[@]}"; do
                        to_delete+=("${empty_dirs[$((idx-1))]}")
                    done
                    
                    echo "即将删除以下目录："
                    for dir in "${to_delete[@]}"; do
                        echo "- $(basename "$(dirname "$dir")")/$(basename "$dir")"
                    done
                    echo -n "确认删除? (y/n): "
                    read -r confirm
                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                        for dir in "${to_delete[@]}"; do
                            delete_chat_dir "$dir"
                        done
                        echo "已删除选定的目录"
                        
                        # 对未删除的目录执行清理
                        for dir in "${empty_dirs[@]}"; do
                            # 检查是否在要删除的列表中
                            local should_clean=1
                            for del_dir in "${to_delete[@]}"; do
                                if [ "$dir" = "$del_dir" ]; then
                                    should_clean=0
                                    break
                                fi
                            done
                            
                            # 如果不在删除列表中，则清理
                            if [ $should_clean -eq 1 ]; then
                                direct_cleanup_range "$dir" "$actual_start" "$actual_end"
                            fi
                        done
                    else
                        echo "取消删除操作"
                        # 仍然执行清理
                        for dir in "${empty_dirs[@]}"; do
                            direct_cleanup_range "$dir" "$actual_start" "$actual_end"
                        done
                        echo "已清理文件但保留目录"
                    fi
                fi
                ;;
            3)
                # 保留目录但清理文件
                echo "保留所有目录，仅清理文件..."
                for dir in "${empty_dirs[@]}"; do
                    direct_cleanup_range "$dir" "$actual_start" "$actual_end"
                done
                echo "已清理文件但保留目录"
                ;;
            4)
                echo "操作已取消"
                press_any_key
                return
                ;;
            *)
                echo "操作已取消"
                press_any_key
                return
                ;;
        esac
    fi
    
    # 如果有找到单文件目录，集中处理
    if [ ${#single_file_dirs[@]} -gt 0 ]; then
        echo ""
        echo "找到 ${#single_file_dirs[@]} 个只有单个文件的目录："
        
        # 显示这些目录和文件
        for i in "${!single_file_dirs[@]}"; do
            local dir="${single_file_dirs[$i]}"
            local file="${single_file_paths[$i]}"
            
            # 提取角色名和聊天ID
            local rel_path="${dir#$SAVE_BASE_DIR/}"
            local char_name=$(basename "$(dirname "$dir")")
            local chat_id=$(basename "$dir")
            
            echo "$((i+1)). ${char_name}/${chat_id}/$(basename "$file")"
        done
        
        echo ""
        echo "请选择要删除的单文件目录："
        echo "可以输入："
        echo "- 序号范围（如 1-3）"
        echo "- 逗号分隔的序号（如 1,3,5）"
        echo "- 混合使用（如 1-3,5,7-9）"
        echo "- 输入'全选'删除所有单文件目录"
        echo "- 输入'跳过'保留所有单文件目录"
        echo -n "您的选择: "
        read -r selection
        
        # 处理用户输入
        if [ "$selection" = "跳过" ]; then
            echo "保留所有单文件目录"
        elif [ "$selection" = "全选" ]; then
            echo "将删除所有单文件目录中的文件"
            for file in "${single_file_paths[@]}"; do
                rm "$file"
                echo "删除文件: $file"
            done
        else
            # 处理选择的范围
            selected_indices=($(process_range_selection "$selection" ${#single_file_dirs[@]}))
            
            if [ ${#selected_indices[@]} -gt 0 ]; then
                echo "将删除以下文件:"
                for idx in "${selected_indices[@]}"; do
                    echo "- ${single_file_paths[$((idx-1))]}"
                done
                
                echo -n "确认删除? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    for idx in "${selected_indices[@]}"; do
                        rm "${single_file_paths[$((idx-1))]}"
                        echo "删除文件: ${single_file_paths[$((idx-1))]}"
                    done
                else
                    echo "取消删除操作"
                fi
            else
                echo "未选择任何文件，保留所有单文件目录"
            fi
        fi
    fi
    
    echo "清理完成！"
    press_any_key
}

# 直接清除特定目录范围的文件，仅显示统计信息
direct_cleanup_range() {
    local dir="$1"
    local start_floor="$2"
    local end_floor="$3"
    
    if [ ! -d "$dir" ]; then
        return
    fi
    
    local deleted_count=0
    
    # 找出要删除的文件
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$floor" ] && [ "$floor" -ge "$start_floor" ] && [ "$floor" -le "$end_floor" ]; then
            rm "$file"
            deleted_count=$((deleted_count + 1))
        fi
    done
    
    if [ $deleted_count -gt 0 ]; then
        echo "从 $(basename "$(dirname "$dir")")/$(basename "$dir") 删除了 $deleted_count 个文件"
    fi
}

# 清理指定目录的冗余存档
cleanup_chat_dir() {
    local dir="$1"
    local latest_floor=0
    local files_to_keep=()
    
    echo "清理目录: $dir"
    
    # 找出最新楼层和需要保留的楼层文件
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        # 更新最新楼层
        if [ -n "$floor" ] && [ "$floor" -gt "$latest_floor" ]; then
            latest_floor=$floor
        fi
    done
    
    # 如果没有找到楼层，直接返回
    if [ "$latest_floor" -eq 0 ]; then
        echo "目录中没有楼层文件: $dir"
        return
    fi
    
    # 确定要保留的文件
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$floor" ] && should_save_floor "$floor" "$latest_floor" "$dir"; then
            files_to_keep+=("$file")
        fi
    done
    
    # 删除不需要保留的文件
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        keep=0
        for keep_file in "${files_to_keep[@]}"; do
            if [ "$file" = "$keep_file" ]; then
                keep=1
                break
            fi
        done
        
        if [ $keep -eq 0 ]; then
            rm "$file"
            echo "删除文件: $file"
        fi
    done
}

# 单键输入(无需回车确认)
get_single_key() {
    # 保存当前终端设置
    old_tty=$(stty -g)
    # 设置终端为无缓冲模式
    stty -icanon -echo
    # 读取单个字符
    dd if=/dev/tty bs=1 count=1 2>/dev/null
    # 恢复终端设置
    stty "$old_tty"
}

# 按任意键继续
press_any_key() {
    echo "按任意键继续..."
    get_single_key >/dev/null
}

# 清除特定目录范围的文件
cleanup_range() {
    local dir="$1"
    local start_floor="$2"
    local end_floor="$3"
    
    if [ ! -d "$dir" ]; then
        echo "目录不存在: $dir"
        return
    fi
    
    echo "清除 $dir 中 ${start_floor}楼 - ${end_floor}楼 的文件..."
    
    # 计算目录中文件总数
    local total_files=$(count_files_in_dir "$dir")
    
    # 如果目录中只有一个文件，询问是否删除
    if [ "$total_files" -eq 1 ]; then
        echo "警告：该目录只有一个文件。"
        echo -n "是否删除？(y/n): "
        read -r confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            # 删除唯一的文件
            for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
                [ -f "$file" ] || continue
                rm "$file"
                echo "删除文件: $file"
            done
            echo "文件已删除"
            return
        else
            echo "保留唯一文件，跳过清理"
            return
        fi
    fi
    
    # 找出最新楼层
    local latest_floor=0
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$floor" ] && [ "$floor" -gt "$latest_floor" ]; then
            latest_floor=$floor
        fi
    done
    
    # 找出要删除的文件
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        
        # 提取楼层数
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        
        if [ -n "$floor" ] && [ "$floor" -ge "$start_floor" ] && [ "$floor" -le "$end_floor" ]; then
            # 检查是否应该保留
            if should_save_floor "$floor" "$latest_floor" "$dir"; then
                echo "保留符合保留条件的文件: $file"
                continue
            fi
            
            rm "$file"
            echo "删除文件: $file"
        fi
    done
    
    echo "清除完成！"
}

# 显示规则
display_rule() {
    local rule="$1"
    local index="$2"
    local mode="${3:-full}"
    
    # 解析规则
    read -r rule_type params <<< $(parse_rule "$rule")
    
    case "$rule_type" in
        "interval_above")
            IFS=',' read -r min_floor range interval <<< "$params"
            if [ "$mode" = "compact" ]; then
                echo -e "\033[33m${min_floor}楼以上只保存最近${range}楼内${interval}的倍数\033[0m"
            else
                echo -e "$index. \033[33m${min_floor}楼以上只保存最近${range}楼内${interval}的倍数\033[0m"
            fi
            ;;
        "latest_above")
            if [ "$mode" = "compact" ]; then
                echo -e "\033[33m${params}楼以上只保留最高楼层\033[0m"
            else
                echo -e "$index. \033[33m${params}楼以上只保留最高楼层\033[0m"
            fi
            ;;
        *)
            if [ "$mode" = "compact" ]; then
                echo -e "\033[31m未知规则类型\033[0m"
            else
                echo -e "$index. \033[31m未知规则类型\033[0m"
            fi
            ;;
    esac
}


# 显示规则菜单
rules_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 自定义规则 ====="
        echo -e "\033[34m全局规则:\033[0m"
        if [ ${#GLOBAL_RULES[@]} -eq 0 ]; then
            echo "无"
        else
            for i in "${!GLOBAL_RULES[@]}"; do
                display_rule "${GLOBAL_RULES[$i]}" "$((i+1))"
            done
        fi
        
        echo -e "\n\033[34m文件夹局部规则:\033[0m"
        display_all_rules
        
        echo ""
        echo "1. 全局规则"
        echo "2. 文件夹局部规则"
        echo "3. 返回设置菜单"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1) global_rules_menu ;;
            2) local_rules_menu ;;
            3) return ;;
            *) echo "无效选择"; press_any_key ;;
        esac
    done
}




# 全局规则菜单
global_rules_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 全局规则 ====="
        
        # 显示当前生效的规则
        if [ ${#GLOBAL_RULES[@]} -gt 0 ]; then
            echo "当前使用全局规则:"
            for i in "${!GLOBAL_RULES[@]}"; do
                display_rule "${GLOBAL_RULES[$i]}" "$((i+1))"
            done
        else
            echo "当前无自定义规则"
        fi
        
        echo ""
        echo "1. 新增规则"
        echo "2. 修改规则"
        echo "3. 删除规则"
        echo "4. 返回上一级"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                # 新增规则
                add_rule "global"
                ;;
            2)
                # 修改规则
                if [ ${#GLOBAL_RULES[@]} -eq 0 ]; then
                    echo "暂无规则可修改"
                    press_any_key
                    continue
                fi
                
                echo -n "选择要修改的规则编号: "
                read -r rule_idx
                
                if [[ $rule_idx =~ ^[0-9]+$ ]] && [ "$rule_idx" -ge 1 ] && [ "$rule_idx" -le "${#GLOBAL_RULES[@]}" ]; then
                    edit_rule "global" "$((rule_idx-1))"
                else
                    echo "无效的规则编号"
                    press_any_key
                fi
                ;;
            3)
                # 删除规则
                if [ ${#GLOBAL_RULES[@]} -eq 0 ]; then
                    echo "暂无规则可删除"
                    press_any_key
                    continue
                fi
                
                echo "请指定要删除的规则："
                echo "可以输入："
                echo "- 序号范围（如 1-3）"
                echo "- 逗号分隔的序号（如 1,3,5）"
                echo "- 混合使用（如 1-3,5,7-9）"
                echo "- 输入'全选'删除所有规则"
                echo -n "输入要删除的规则: "
                read -r range
                
                # 处理选择
                selected_indices=($(process_range_selection "$range" ${#GLOBAL_RULES[@]}))
                
                if [ ${#selected_indices[@]} -eq 0 ]; then
                    echo "未选择任何有效规则，取消删除操作"
                else
                    # 从大到小排序，以便从后往前删除不影响索引
                    IFS=$'\n' selected_indices=($(sort -nr <<<"${selected_indices[*]}"))
                    
                    echo "即将删除以下规则："
                    for idx in "${selected_indices[@]}"; do
                        display_rule "${GLOBAL_RULES[$((idx-1))]}" "$idx"
                    done
                    
                    echo -n "确认删除? (y/n): "
                    read -r confirm
                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                        for idx in "${selected_indices[@]}"; do
                            unset 'GLOBAL_RULES[$((idx-1))]'
                        done
                        # 重建数组以消除空洞
                        GLOBAL_RULES=("${GLOBAL_RULES[@]}")
                        save_rules
                        echo "已删除选定的规则"
                    else
                        echo "取消删除操作"
                    fi
                fi
                press_any_key
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}

# 新增的辅助函数
display_all_rules() {
    # 角色规则
    echo -e "\033[34m角色规则:\033[0m"
    if [ ${#CHAR_RULES[@]} -eq 0 ]; then
        echo "无"
    else
        local char_index=1
        for char_name in "${!CHAR_RULES[@]}"; do
            echo -n "$char_index - $char_name: "
            display_rule "${CHAR_RULES[$char_name]}" "1" "compact"
            char_index=$((char_index+1))
        done
    fi
    
    # 聊天记录规则
    echo -e "\n\033[34m聊天记录规则:\033[0m"
    if [ ${#CHAT_RULES[@]} -eq 0 ]; then
        echo "无"
    else
        local chat_index=1
        for chat_key in "${!CHAT_RULES[@]}"; do
            char_name="${chat_key%%/*}"
            chat_id="${chat_key#*/}"
            echo -n "$chat_index - $char_name - $chat_id: "
            display_rule "${CHAT_RULES[$chat_key]}" "1" "compact"
            chat_index=$((chat_index+1))
        done
    fi
}


handle_existing_rule() {
    local rule_type="$1"
    local target="$2"
    
    while true; do
        clear
        echo "===== 已有规则管理 ====="
        echo "目标: $target"
        
        if [ "$rule_type" = "char" ]; then
            rule="${CHAR_RULES[$target]}"
        else
            rule="${CHAT_RULES[$target]}"
        fi
        
        display_rule "$rule" "1"
        echo ""
        echo "1. 修改规则"
        echo "2. 删除规则"
        echo "3. 返回"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                edit_rule "$rule_type" "$target"
                return 0
                ;;
            2)
                echo -n "确认删除此规则? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    if [ "$rule_type" = "char" ]; then
                        unset "CHAR_RULES[$target]"
                    else
                        unset "CHAT_RULES[$target]"
                    fi
                    save_rules
                    echo "规则已删除"
                    press_any_key
                    return 1
                fi
                ;;
            3)
                return 1
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}

local_rules_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 文件夹局部规则 ====="
        display_all_rules
        echo ""
        echo "1. 选择文件夹"
        echo "2. 输入角色名称"
        echo "3. 管理已有规则"
        echo "4. 返回上一级"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1) browse_folders ;;
            2) search_by_name ;;
            3) manage_existing_rules ;;
            4) return ;;
            *) echo "无效选择"; press_any_key ;;
        esac
    done
}

manage_existing_rules() {
    while true; do
        clear
        echo "===== 管理已有规则 ====="
        
        # 显示角色规则
        echo -e "\033[34m角色规则:\033[0m"
        if [ ${#CHAR_RULES[@]} -eq 0 ]; then
            echo "无"
        else
            local char_index=1
            for char_name in "${!CHAR_RULES[@]}"; do
                echo "$char_index - $char_name: "
                display_rule "${CHAR_RULES[$char_name]}" "1" "compact"
                char_index=$((char_index+1))
            done
        fi
        
        # 显示聊天记录规则
        echo -e "\n\033[34m聊天记录规则:\033[0m"
        if [ ${#CHAT_RULES[@]} -eq 0 ]; then
            echo "无"
        else
            local chat_index=1
            for chat_key in "${!CHAT_RULES[@]}"; do
                char_name="${chat_key%%/*}"
                chat_id="${chat_key#*/}"
                echo "$chat_index - $char_name - $chat_id: "
                display_rule "${CHAT_RULES[$chat_key]}" "1" "compact"
                chat_index=$((chat_index+1))
            done
        fi
        
        echo ""
        echo "1. 修改规则"
        echo "2. 删除规则"
        echo "3. 返回"
        echo -n "选择操作: "
        read -r action_choice
        
        case "$action_choice" in
            1|2)
                echo -n "请输入要操作的规则类型 (1=角色规则, 2=聊天记录规则): "
                read -r rule_type
                
                echo -n "请输入规则序号: "
                read -r rule_index
                
                if [ "$rule_type" = "1" ]; then
                    # 处理角色规则
                    if [ ${#CHAR_RULES[@]} -eq 0 ]; then
                        echo "没有角色规则可操作"
                        press_any_key
                        continue
                    fi
                    
                    if [[ ! $rule_index =~ ^[0-9]+$ ]] || [ "$rule_index" -lt 1 ] || [ "$rule_index" -gt "${#CHAR_RULES[@]}" ]; then
                        echo "无效的规则序号"
                        press_any_key
                        continue
                    fi
                    
                    local selected_char=$(printf '%s\n' "${!CHAR_RULES[@]}" | sed -n "${rule_index}p")
                    
                    if [ "$action_choice" = "1" ]; then
                        # 修改角色规则
                        edit_rule "char" "$selected_char"
                    else
                        # 删除角色规则
                        echo -n "确认删除角色 [$selected_char] 的规则? (y/n): "
                        read -r confirm
                        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                            unset "CHAR_RULES[$selected_char]"
                            save_rules
                            echo "规则已删除"
                            press_any_key
                        fi
                    fi
                elif [ "$rule_type" = "2" ]; then
                    # 处理聊天记录规则
                    if [ ${#CHAT_RULES[@]} -eq 0 ]; then
                        echo "没有聊天记录规则可操作"
                        press_any_key
                        continue
                    fi
                    
                    if [[ ! $rule_index =~ ^[0-9]+$ ]] || [ "$rule_index" -lt 1 ] || [ "$rule_index" -gt "${#CHAT_RULES[@]}" ]; then
                        echo "无效的规则序号"
                        press_any_key
                        continue
                    fi
                    
                    local selected_chat=$(printf '%s\n' "${!CHAT_RULES[@]}" | sed -n "${rule_index}p")
                    
                    if [ "$action_choice" = "1" ]; then
                        # 修改聊天记录规则
                        edit_rule "chat" "$selected_chat"
                    else
                        # 删除聊天记录规则
                        echo -n "确认删除聊天记录 [$selected_chat] 的规则? (y/n): "
                        read -r confirm
                        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                            unset "CHAT_RULES[$selected_chat]"
                            save_rules
                            echo "规则已删除"
                            press_any_key
                        fi
                    fi
                else
                    echo "无效的规则类型"
                    press_any_key
                fi
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}


select_rule_to_manage() {
    local rule_type="$1"
    
    clear
    echo "===== 选择要管理的规则 ====="
    
    if [ "$rule_type" = "char" ]; then
        echo -e "\033[34m角色规则:\033[0m"
        if [ ${#CHAR_RULES[@]} -eq 0 ]; then
            echo "无"
            press_any_key
            return
        fi
        
        local index=1
        for char_name in "${!CHAR_RULES[@]}"; do
            echo "$index - $char_name"
            index=$((index+1))
        done
        
        echo -n "选择要管理的角色规则编号: "
        read -r choice
        
        if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#CHAR_RULES[@]}" ]; then
            echo "无效选择"
            press_any_key
            return
        fi
        
        local selected_char=$(printf '%s\n' "${!CHAR_RULES[@]}" | sed -n "${choice}p")
        edit_or_delete_rule "char" "$selected_char"
    else
        echo -e "\033[34m聊天记录规则:\033[0m"
        if [ ${#CHAT_RULES[@]} -eq 0 ]; then
            echo "无"
            press_any_key
            return
        fi
        
        local index=1
        for chat_key in "${!CHAT_RULES[@]}"; do
            char_name="${chat_key%%/*}"
            chat_id="${chat_key#*/}"
            echo "$index - $char_name - $chat_id"
            index=$((index+1))
        done
        
        echo -n "选择要管理的聊天记录规则编号: "
        read -r choice
        
        if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#CHAT_RULES[@]}" ]; then
            echo "无效选择"
            press_any_key
            return
        fi
        
        local selected_chat=$(printf '%s\n' "${!CHAT_RULES[@]}" | sed -n "${choice}p")
        edit_or_delete_rule "chat" "$selected_chat"
    fi
}

edit_or_delete_rule() {
    local rule_type="$1"
    local target="$2"
    
    while true; do
        clear
        echo "===== 规则管理 ====="
        echo "目标: $target"
        
        if [ "$rule_type" = "char" ]; then
            rule="${CHAR_RULES[$target]}"
        else
            rule="${CHAT_RULES[$target]}"
        fi
        
        display_rule "$rule" "1"
        echo ""
        echo "1. 修改规则"
        echo "2. 删除规则"
        echo "3. 返回"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                edit_rule "$rule_type" "$target"
                return
                ;;
            2)
                echo -n "确认删除此规则? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    if [ "$rule_type" = "char" ]; then
                        unset "CHAR_RULES[$target]"
                    else
                        unset "CHAT_RULES[$target]"
                    fi
                    save_rules
                    echo "规则已删除"
                    press_any_key
                    return
                fi
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}

browse_folders() {
    ask_sort_method
    
    # 收集所有角色目录
    char_dirs=()
    while IFS= read -r dir; do
        if [ -d "$dir" ]; then
            char_dirs+=("$dir")
        fi
    done < <(find "$SAVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    
    # 排序目录
    sorted_char_dirs=($(sort_directories "${char_dirs[@]}"))
    
    # 显示排序后的目录
    echo "选择角色目录:"
    i=0
    for dir in "${sorted_char_dirs[@]}"; do
        char_name=$(basename "$dir")
        if [ -n "${CHAR_RULES[$char_name]}" ]; then
            echo -e "$((++i)) - \033[33m$char_name\033[0m (已有规则)"
        else
            echo "$((++i)) - $char_name"
        fi
    done
    
    if [ ${#sorted_char_dirs[@]} -eq 0 ]; then
        echo "没有角色目录或目录路径有误: $SAVE_BASE_DIR"
        press_any_key
        return
    fi
    
    # 选择角色目录
    echo -n "选择目录编号(按回车确认，按s切换排序顺序): "
    read -r choice
    
    # 检查是否是切换排序顺序
    if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
        if [ "$SORT_ORDER" = "asc" ]; then
            SORT_ORDER="desc"
            echo "已切换为降序排列："
        else
            SORT_ORDER="asc"
            echo "已切换为升序排列："
        fi
        save_config
        
        # 直接重新排序并显示，不清屏
        sorted_char_dirs=($(sort_directories "${char_dirs[@]}"))
        i=0
        for dir in "${sorted_char_dirs[@]}"; do
            char_name=$(basename "$dir")
            if [ -n "${CHAR_RULES[$char_name]}" ]; then
                echo -e "$((++i)) - \033[33m$char_name\033[0m (已有规则)"
            else
                echo "$((++i)) - $char_name"
            fi
        done
        
        echo -n "选择目录编号(按回车确认，按s切换排序顺序): "
        read -r choice
    fi
    
    if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#sorted_char_dirs[@]}" ]; then
        echo "无效选择"
        press_any_key
        return
    fi
    
    selected_char_dir="${sorted_char_dirs[$((choice-1))]}"
    char_name=$(basename "$selected_char_dir")
    
    # 询问应用范围
    echo "1. 对该角色起效"
    echo "2. 对单独聊天记录起效"
    echo -n "选择(1/2): "
    scope_choice=$(get_single_key)
    echo "$scope_choice"
    
    if [ "$scope_choice" = "1" ]; then
        # 修复: 不管是否有规则，直接进入角色规则菜单让用户处理
        char_rules_menu "$char_name"
    elif [ "$scope_choice" = "2" ]; then
        select_chat_dir "$char_name"
    else
        echo "无效选择"
        press_any_key
    fi
}

select_chat_dir() {
    local char_name="$1"
    # 使用双引号确保空格被正确处理
    local char_dir="$SAVE_BASE_DIR/$char_name"
    
    echo "选择聊天记录目录:"
    echo "提示: 可以使用逗号或空格分隔多个编号进行多选"
    echo "      也可以输入范围 (如1-5) 或输入'全选'选择所有目录"
    
    chat_dirs=()
    i=0
    # 使用引号包裹变量以处理路径中的空格
    while IFS= read -r dir; do
        if [ -d "$dir" ]; then
            if [ -n "$(find "$dir" -type f 2>/dev/null)" ]; then
                chat_dirs+=("$dir")
                read floor_min floor_max < <(get_floor_range "$dir")
                total_files=$(count_files_in_dir "$dir")
                echo "$((++i)). $(basename "$dir") (${floor_min}楼-${floor_max}楼, 共${total_files}个文件)"
            fi
        fi
    done < <(find "$char_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    
    if [ ${#chat_dirs[@]} -eq 0 ]; then
        echo "没有聊天记录目录或目录不存在: $char_dir"
        press_any_key
        return
    fi
    
    # 用户选择聊天记录目录
    echo -n "选择目录编号(可用逗号或空格分隔多选，按回车确认): "
    read -r chat_choice
    
    # 处理多选
    selected_indices=($(process_range_selection "$chat_choice" ${#chat_dirs[@]}))
    
    if [ ${#selected_indices[@]} -eq 0 ]; then
        echo "无效选择"
        press_any_key
        return
    fi
    
    # 处理每个选中的聊天记录目录
    for idx in "${selected_indices[@]}"; do
        chat_dir="${chat_dirs[$((idx-1))]}"
        chat_id=$(basename "$chat_dir")
        chat_key="${char_name}/${chat_id}"
        
        if [ -n "${CHAT_RULES[$chat_key]}" ]; then
            if handle_existing_rule "chat" "$chat_key"; then
                continue
            fi
        fi
        
        chat_rules_menu "$char_name" "$chat_id"
    done
}

search_by_name() {
    echo -n "输入角色名称(支持模糊匹配，按回车确认): "
    read -r search_name
    
    if [ -z "$search_name" ]; then
        echo "角色名称不能为空"
        press_any_key
        return
    fi
    
    # 查找匹配的角色目录
    matched_dirs=()
    while IFS= read -r dir; do
        if [ -d "$dir" ]; then
            dir_name=$(basename "$dir")
            if [[ "$dir_name" == *"$search_name"* ]]; then
                matched_dirs+=("$dir")
            fi
        fi
    done < <(find "$SAVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    
    if [ ${#matched_dirs[@]} -eq 0 ]; then
        echo "没有找到匹配的角色目录"
        press_any_key
        return
    fi
    
    # 显示匹配结果
    echo "找到 ${#matched_dirs[@]} 个匹配结果:"
    i=0
    for dir in "${matched_dirs[@]}"; do
        char_name=$(basename "$dir")
        if [ -n "${CHAR_RULES[$char_name]}" ]; then
            echo -e "$((++i)) - \033[33m$char_name\033[0m (已有规则)"
        else
            echo "$((++i)) - $char_name"
        fi
    done
    
    # 选择具体角色
    echo -n "选择角色编号(按回车确认): "
    read -r choice
    
    if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#matched_dirs[@]}" ]; then
        echo "无效选择"
        press_any_key
        return
    fi
    
    selected_char_dir="${matched_dirs[$((choice-1))]}"
    char_name=$(basename "$selected_char_dir")
    
    # 询问应用范围
    echo "1. 对该角色起效"
    echo "2. 对单独聊天记录起效"
    echo -n "选择(1/2): "
    scope_choice=$(get_single_key)
    echo "$scope_choice"
    
    if [ "$scope_choice" = "1" ]; then
        # 修复: 不管是否有规则，直接进入角色规则菜单让用户处理
        char_rules_menu "$char_name"
    elif [ "$scope_choice" = "2" ]; then
        select_chat_dir "$char_name"
    else
        echo "无效选择"
        press_any_key
    fi
}




# 角色规则菜单
char_rules_menu() {
    local char_name="$1"
    
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 角色规则: $char_name ====="
        
        # 显示该角色的规则
        if [ -z "${CHAR_RULES[$char_name]}" ]; then
            echo "该角色暂无自定义规则"
        else
            echo "现有角色规则:"
            display_rule "${CHAR_RULES[$char_name]}" "1"
        fi
        
        echo ""
        echo "1. 新增规则"
        echo "2. 修改规则"
        echo "3. 删除规则"
        echo "4. 返回上一级"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                # 新增规则
                if [ -n "${CHAR_RULES[$char_name]}" ]; then
                    echo "该角色已有规则，请先删除现有规则"
                    press_any_key
                    continue
                fi
                add_rule "char" "$char_name"
                ;;
            2)
                # 修改规则
                if [ -z "${CHAR_RULES[$char_name]}" ]; then
                    echo "该角色暂无规则可修改"
                    press_any_key
                    continue
                fi
                edit_rule "char" "$char_name"
                ;;
            3)
                # 删除规则
                if [ -z "${CHAR_RULES[$char_name]}" ]; then
                    echo "该角色暂无规则可删除"
                    press_any_key
                    continue
                fi
                
                echo -n "确认删除该角色规则? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    unset "CHAR_RULES[$char_name]"
                    save_rules
                    echo "已删除该角色规则"
                else
                    echo "取消删除操作"
                fi
                press_any_key
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}

# 聊天记录规则菜单
chat_rules_menu() {
    local char_name="$1"
    local chat_id="$2"
    local chat_key="${char_name}/${chat_id}"
    
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 聊天记录规则: $chat_id ====="
        
        # 显示该聊天记录的规则
        if [ -z "${CHAT_RULES[$chat_key]}" ]; then
            echo "该聊天记录暂无自定义规则"
        else
            echo "现有聊天记录规则:"
            display_rule "${CHAT_RULES[$chat_key]}" "1"
        fi
        
        echo ""
        echo "1. 新增规则"
        echo "2. 修改规则"
        echo "3. 删除规则"
        echo "4. 返回上一级"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                # 新增规则
                if [ -n "${CHAT_RULES[$chat_key]}" ]; then
                    echo "该聊天记录已有规则，请先删除现有规则"
                    press_any_key
                    continue
                fi
                add_rule "chat" "$chat_key"
                ;;
            2)
                # 修改规则
                if [ -z "${CHAT_RULES[$chat_key]}" ]; then
                    echo "该聊天记录暂无规则可修改"
                    press_any_key
                    continue
                fi
                edit_rule "chat" "$chat_key"
                ;;
            3)
                # 删除规则
                if [ -z "${CHAT_RULES[$chat_key]}" ]; then
                    echo "该聊天记录暂无规则可删除"
                    press_any_key
                    continue
                fi
                
                echo -n "确认删除该聊天记录规则? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    unset "CHAT_RULES[$chat_key]"
                    save_rules
                    echo "已删除该聊天记录规则"
                else
                    echo "取消删除操作"
                fi
                press_any_key
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}

# 添加规则
add_rule() {
    local rule_scope="$1"  # global, char, chat
    local target="$2"      # 角色名或聊天记录路径
    
    echo "规则模板:"
    echo "1. __楼以上只保存最近__楼内__的倍数"
    echo "2. __楼以上只保留最高楼层"
    echo -n "选择规则模板(1/2): "
    choice=$(get_single_key)
    echo "$choice"
    
    if [ "$choice" = "1" ]; then
        # __楼以上只保存最近__楼内__的倍数
        echo -n "请输入三个参数(用逗号或空格分隔): "
        read -r params
        
        # 替换中文逗号为英文逗号
        params=${params//，/,}
        # 替换空格为逗号
        params=${params// /,}
        
        # 分割参数
        IFS=',' read -ra parts <<< "$params"
        
        if [ ${#parts[@]} -ne 3 ]; then
            echo "参数数量不正确，需要三个参数"
            press_any_key
            return
        fi
        
        local min_floor="${parts[0]}"
        local range="${parts[1]}"
        local interval="${parts[2]}"
        
        if [[ ! $min_floor =~ ^[0-9]+$ ]] || [[ ! $range =~ ^[0-9]+$ ]] || [[ ! $interval =~ ^[0-9]+$ ]]; then
            echo "参数必须为数字"
            press_any_key
            return
        fi
        
        # 生成规则字符串
        local rule="interval_above:$min_floor,$range,$interval"
        
        # 根据作用域保存规则
        if [ "$rule_scope" = "global" ]; then
            GLOBAL_RULES+=("$rule")
        elif [ "$rule_scope" = "char" ]; then
            CHAR_RULES["$target"]="$rule"
        elif [ "$rule_scope" = "chat" ]; then
            CHAT_RULES["$target"]="$rule"
        fi
        
        save_rules
        echo "规则添加成功！"
        press_any_key
        
    elif [ "$choice" = "2" ]; then
        # __楼以上只保留最高楼层
        echo -n "请输入起始楼层: "
        read -r min_floor
        
        if [[ ! $min_floor =~ ^[0-9]+$ ]]; then
            echo "楼层必须为数字"
            press_any_key
            return
        fi
        
        # 生成规则字符串
        local rule="latest_above:$min_floor"
        
        # 根据作用域保存规则
        if [ "$rule_scope" = "global" ]; then
            GLOBAL_RULES+=("$rule")
        elif [ "$rule_scope" = "char" ]; then
            CHAR_RULES["$target"]="$rule"
        elif [ "$rule_scope" = "chat" ]; then
            CHAT_RULES["$target"]="$rule"
        fi
        
        save_rules
        echo "规则添加成功！"
        press_any_key
    else
        echo "无效选择"
        press_any_key
    fi
}

# 编辑规则
edit_rule() {
    local rule_scope="$1"  # global, char, chat
    local target="$2"      # 索引、角色名或聊天记录路径
    
    local rule=""
    
    # 获取现有规则
    if [ "$rule_scope" = "global" ]; then
        rule="${GLOBAL_RULES[$target]}"
    elif [ "$rule_scope" = "char" ]; then
        rule="${CHAR_RULES[$target]}"
    elif [ "$rule_scope" = "chat" ]; then
        rule="${CHAT_RULES[$target]}"
    fi
    
    # 分析规则类型
    if [[ "$rule" == interval_above:* ]]; then
        # 处理interval_above:格式
        local params="${rule#interval_above:}"
        IFS=',' read -ra args <<< "$params"
        local min_floor="${args[0]}"
        local range="${args[1]}"
        local interval="${args[2]}"
        
        echo "当前规则: ${min_floor}楼以上只保存最近${range}楼内${interval}的倍数"
        echo -n "请输入新的三个参数(用逗号或空格分隔): "
        read -r params
        
        # 替换中文逗号为英文逗号
        params=${params//，/,}
        # 替换空格为逗号
        params=${params// /,}
        
        # 分割参数
        IFS=',' read -ra parts <<< "$params"
        
        if [ ${#parts[@]} -ne 3 ]; then
            echo "参数数量不正确，需要三个参数"
            press_any_key
            return
        fi
        
        local new_min_floor="${parts[0]}"
        local new_range="${parts[1]}"
        local new_interval="${parts[2]}"
        
        if [[ ! $new_min_floor =~ ^[0-9]+$ ]] || [[ ! $new_range =~ ^[0-9]+$ ]] || [[ ! $new_interval =~ ^[0-9]+$ ]]; then
            echo "参数必须为数字"
            press_any_key
            return
        fi
        
        # 生成新规则字符串
        local new_rule="interval_above:$new_min_floor,$new_range,$new_interval"
        
        # 更新规则
        if [ "$rule_scope" = "global" ]; then
            GLOBAL_RULES[$target]="$new_rule"
        elif [ "$rule_scope" = "char" ]; then
            CHAR_RULES["$target"]="$new_rule"
        elif [ "$rule_scope" = "chat" ]; then
            CHAT_RULES["$target"]="$new_rule"
        fi
        
    elif [[ "$rule" == latest_above:* ]]; then
        # 处理latest_above:格式
        local min_floor="${rule#latest_above:}"
        
        echo "当前规则: ${min_floor}楼以上只保留最高楼层"
        echo -n "请输入新的起始楼层: "
        read -r new_min_floor
        
        if [[ ! $new_min_floor =~ ^[0-9]+$ ]]; then
            echo "楼层必须为数字"
            press_any_key
            return
        fi
        
        # 生成新规则字符串
        local new_rule="latest_above:$new_min_floor"
        
        # 更新规则
        if [ "$rule_scope" = "global" ]; then
            GLOBAL_RULES[$target]="$new_rule"
        elif [ "$rule_scope" = "char" ]; then
            CHAR_RULES["$target"]="$new_rule"
        elif [ "$rule_scope" = "chat" ]; then
            CHAT_RULES["$target"]="$new_rule"
        fi
    
    elif [[ "$rule" == interval_above* ]]; then
        # 处理空格分隔的interval_above格式
        local params="${rule#interval_above }"
        IFS=',' read -ra args <<< "$params"
        local min_floor="${args[0]}"
        local range="${args[1]}"
        local interval="${args[2]}"
        
        echo "当前规则: ${min_floor}楼以上只保存最近${range}楼内${interval}的倍数"
        echo -n "请输入新的三个参数(用逗号或空格分隔): "
        read -r params
        
        # 替换中文逗号为英文逗号
        params=${params//，/,}
        # 替换空格为逗号
        params=${params// /,}
        
        # 分割参数
        IFS=',' read -ra parts <<< "$params"
        
        if [ ${#parts[@]} -ne 3 ]; then
            echo "参数数量不正确，需要三个参数"
            press_any_key
            return
        fi
        
        local new_min_floor="${parts[0]}"
        local new_range="${parts[1]}"
        local new_interval="${parts[2]}"
        
        if [[ ! $new_min_floor =~ ^[0-9]+$ ]] || [[ ! $new_range =~ ^[0-9]+$ ]] || [[ ! $new_interval =~ ^[0-9]+$ ]]; then
            echo "参数必须为数字"
            press_any_key
            return
        fi
        
        # 生成新规则字符串
        local new_rule="interval_above:$new_min_floor,$new_range,$new_interval"
        
        # 更新规则
        if [ "$rule_scope" = "global" ]; then
            GLOBAL_RULES[$target]="$new_rule"
        elif [ "$rule_scope" = "char" ]; then
            CHAR_RULES["$target"]="$new_rule"
        elif [ "$rule_scope" = "chat" ]; then
            CHAT_RULES["$target"]="$new_rule"
        fi
        
    elif [[ "$rule" == latest_above* ]]; then
        # 处理空格分隔的latest_above格式
        local min_floor="${rule#latest_above }"
        
        echo "当前规则: ${min_floor}楼以上只保留最高楼层"
        echo -n "请输入新的起始楼层: "
        read -r new_min_floor
        
        if [[ ! $new_min_floor =~ ^[0-9]+$ ]]; then
            echo "楼层必须为数字"
            press_any_key
            return
        fi
        
        # 生成新规则字符串
        local new_rule="latest_above:$new_min_floor"
        
        # 更新规则
        if [ "$rule_scope" = "global" ]; then
            GLOBAL_RULES[$target]="$new_rule"
        elif [ "$rule_scope" = "char" ]; then
            CHAR_RULES["$target"]="$new_rule"
        elif [ "$rule_scope" = "chat" ]; then
            CHAT_RULES["$target"]="$new_rule"
        fi
    else
        # 尝试使用parse_rule解析规则
        read -r rule_type params <<< $(parse_rule "$rule")
        
        if [ "$rule_type" = "interval_above" ]; then
            IFS=',' read -ra args <<< "$params"
            if [ ${#args[@]} -lt 3 ]; then
                # 参数不足，使用默认值
                if [ ${#args[@]} -lt 1 ]; then args[0]="5"; fi
                if [ ${#args[@]} -lt 2 ]; then args[1]="5"; fi
                if [ ${#args[@]} -lt 3 ]; then args[2]="2"; fi
            fi
            local min_floor="${args[0]}"
            local range="${args[1]}"
            local interval="${args[2]}"
            
            echo "当前规则: ${min_floor}楼以上只保存最近${range}楼内${interval}的倍数"
            echo -n "请输入新的三个参数(用逗号或空格分隔): "
            read -r params
            
            # 替换中文逗号为英文逗号
            params=${params//，/,}
            # 替换空格为逗号
            params=${params// /,}
            
            # 分割参数
            IFS=',' read -ra parts <<< "$params"
            
            if [ ${#parts[@]} -ne 3 ]; then
                echo "参数数量不正确，需要三个参数"
                press_any_key
                return
            fi
            
            local new_min_floor="${parts[0]}"
            local new_range="${parts[1]}"
            local new_interval="${parts[2]}"
            
            if [[ ! $new_min_floor =~ ^[0-9]+$ ]] || [[ ! $new_range =~ ^[0-9]+$ ]] || [[ ! $new_interval =~ ^[0-9]+$ ]]; then
                echo "参数必须为数字"
                press_any_key
                return
            fi
            
            # 生成新规则字符串
            local new_rule="interval_above:$new_min_floor,$new_range,$new_interval"
            
            # 更新规则
            if [ "$rule_scope" = "global" ]; then
                GLOBAL_RULES[$target]="$new_rule"
            elif [ "$rule_scope" = "char" ]; then
                CHAR_RULES["$target"]="$new_rule"
            elif [ "$rule_scope" = "chat" ]; then
                CHAT_RULES["$target"]="$new_rule"
            fi
            
        elif [ "$rule_type" = "latest_above" ]; then
            local min_floor="$params"
            
            echo "当前规则: ${min_floor}楼以上只保留最高楼层"
            echo -n "请输入新的起始楼层: "
            read -r new_min_floor
            
            if [[ ! $new_min_floor =~ ^[0-9]+$ ]]; then
                echo "楼层必须为数字"
                press_any_key
                return
            fi
            
            # 生成新规则字符串
            local new_rule="latest_above:$new_min_floor"
            
            # 更新规则
            if [ "$rule_scope" = "global" ]; then
                GLOBAL_RULES[$target]="$new_rule"
            elif [ "$rule_scope" = "char" ]; then
                CHAR_RULES["$target"]="$new_rule"
            elif [ "$rule_scope" = "chat" ]; then
                CHAT_RULES["$target"]="$new_rule"
            fi
        else
            echo "无法识别的规则类型: $rule"
            echo "此规则可能已损坏，建议删除后重新添加。"
            press_any_key
            return
        fi
    fi
    
    save_rules
    echo "规则更新成功！"
    press_any_key
}

# 保留机制设置菜单
retention_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 保留机制选择 ====="
        echo -e "当前机制为: $([ "$SAVE_MODE" = "interval" ] && echo "保留\033[33m${SAVE_INTERVAL}\033[0m的倍数和最新楼层" || echo "仅保留最新楼层")"
        echo "1. 保留__的倍数和最新楼层"
        echo "2. 仅保留最新楼层"
        echo "3. 返回设置菜单"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                SAVE_MODE="interval"
                first=$((SAVE_INTERVAL + 1))
                second=$((2 * SAVE_INTERVAL + 1))
                third=$((3 * SAVE_INTERVAL + 1))
                echo -e "\033[32m提示：由于大多数卡有开场白，当前保留倍数为${SAVE_INTERVAL}，保留${first}、${second}、${third}楼……${SAVE_INTERVAL}*n+1楼\033[0m"
                echo -n "请输入保留的倍数(按回车确认): "
                read -r new_interval
                if [[ $new_interval =~ ^[0-9]+$ && $new_interval -gt 0 ]]; then
                    SAVE_INTERVAL=$new_interval
                    echo -e "已设置保留\033[1m${SAVE_INTERVAL}\033[0m的倍数和最新楼层"
                else
                    echo -e "无效输入，使用默认值: \033[1m$SAVE_INTERVAL\033[0m"
                fi
                save_config
                ;;
            2)
                SAVE_MODE="latest"
                save_config
                echo "已设置仅保留最新楼层"
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择"
                ;;
        esac
        press_any_key
    done
}

# 回退处理设置菜单
rollback_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 回退处理 ====="
        echo -e "当前机制为: $([ "$ROLLBACK_MODE" -eq 1 ] && echo "删除重写仅保留最新档" || echo "删除重写保留每个档 (注意：删除前的楼层无论是否是\033[33m${SAVE_INTERVAL}\033[0m的倍数楼都进行保留)")"
        echo "1. 删除重写仅保留最新档"
        echo -e "2. 删除重写保留每个档 (注意：删除前的楼层无论是否是\033[33m${SAVE_INTERVAL}\033[0m的倍数楼都进行保留)"
        echo "3. 返回设置菜单"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                ROLLBACK_MODE=1
                save_config
                echo "已设置回退处理为: 删除重写仅保留最新档"
                ;;
            2)
                ROLLBACK_MODE=2
                save_config
                echo -e "已设置回退处理为: 删除重写保留每个档 \033[1m(注意：删除前的楼层无论是否是${SAVE_INTERVAL}的倍数楼都进行保留)\033[0m"
                ;;
            3)
                return
                ;;
            *)
                echo "无效选择"
                ;;
        esac
        press_any_key
    done
}

# 确认操作
confirm_operation() {
    local message="$1"
    
    echo "$message"
    echo -n "输入【确认】后按回车继续: "
    
    read -r confirm
    
    if [ "$confirm" = "确认" ]; then
        return 0
    else
        echo "操作已取消"
        return 1
    fi
}

# 设置界面
settings_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 设置 ====="
        echo -e "1. 保留机制选择 (当前机制为: $([ "$SAVE_MODE" = "interval" ] && echo "保留\033[33m${SAVE_INTERVAL}\033[0m的倍数和最新楼层" || echo "仅保留最新楼层"))"
        echo -e "2. 回退处理 (当前机制为: $([ "$ROLLBACK_MODE" -eq 1 ] && echo "删除重写仅保留最新档" || echo "删除重写保留每个档"))"
        echo "3. 自定义规则"
        echo "4. 返回主菜单"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                retention_menu
                ;;
            2)
                rollback_menu
                ;;
            3)
                rules_menu
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}

# 清除冗余存档界面 - 修改版支持多选
cleanup_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "===== 清除冗余存档 ====="
        echo "1. 全部聊天"
        echo "2. 选择文件夹"
        echo "3. 输入角色名称"
        echo "4. 返回主菜单"
        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                # 提供选择清理方式
                echo "请选择清理方式:"
                echo "1. 清理楼层范围"
                echo "2. 保留特定倍数楼层"
                echo -n "选择 [1/2]: "
                cleanup_choice=$(get_single_key)
                echo "$cleanup_choice"
                
                if [ "$cleanup_choice" = "1" ]; then
                    cleanup_all_chats
                else
                    cleanup_all_chats_by_multiple
                fi
                ;;
            2)
                # 询问排序方式
                ask_sort_method
                
                # 直接显示一级目录(角色目录)
                echo "选择角色目录:"
                echo "提示: 可以使用逗号或空格分隔多个编号进行多选，多选时将处理所选角色下的所有聊天记录"
                echo "      也可以输入范围 (如1-5) 或输入'全选'选择所有目录"
                
                # 收集所有一级目录
                char_dirs=()
                while IFS= read -r dir; do
                    if [ -d "$dir" ]; then
                        char_dirs+=("$dir")
                    fi
                done < <(find "$SAVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d)
                
                # 排序目录 - 使用NULL分隔符读取结果，避免空格问题
                sorted_char_dirs=()
                while IFS= read -r -d $'\0' dir; do
                    sorted_char_dirs+=("$dir")
                done < <(sort_directories "${char_dirs[@]}")
                
                # 显示排序后的目录
                i=0
                for dir in "${sorted_char_dirs[@]}"; do
                    echo "$((++i)) - $(basename "$dir")"
                done
                
                if [ ${#sorted_char_dirs[@]} -eq 0 ]; then
                    echo "没有角色目录"
                    press_any_key
                    continue
                fi
                
                # 监听切换排序顺序和选择
                echo -n "选择目录编号(可用逗号或空格分隔多选，按回车确认，按s切换排序顺序): "
                read -r choice
                
                # 检查是否是切换排序顺序
                if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
                    if [ "$SORT_ORDER" = "asc" ]; then
                        SORT_ORDER="desc"
                        echo "已切换为降序排列："
                    else
                        SORT_ORDER="asc"
                        echo "已切换为升序排列："
                    fi
                    save_config
                    
                    # 直接重新排序并显示，不清屏
                    sorted_char_dirs=()
                    while IFS= read -r -d $'\0' dir; do
                        sorted_char_dirs+=("$dir")
                    done < <(sort_directories "${char_dirs[@]}")
                    
                    i=0
                    for dir in "${sorted_char_dirs[@]}"; do
                        echo "$((++i)) - $(basename "$dir")"
                    done
                    
                    echo -n "选择目录编号(可用逗号或空格分隔多选，按回车确认，按s切换排序顺序): "
                    read -r choice
                    
                    # 继续检查其他情况
                    if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
                        continue
                    fi
                fi
                
                # 处理多选
                selected_indices=($(process_range_selection "$choice" ${#sorted_char_dirs[@]}))
                
                if [ ${#selected_indices[@]} -eq 0 ]; then
                    echo "无效选择"
                    press_any_key
                    continue
                fi
                
                # 获取选择的目录
                selected_char_dirs=()
                for idx in "${selected_indices[@]}"; do
                    selected_char_dirs+=("${sorted_char_dirs[$((idx-1))]}")
                done
                
                # 如果是多选，直接处理所有子目录
                if [ ${#selected_char_dirs[@]} -gt 1 ]; then
                    echo "您选择了多个角色目录，将处理其下所有聊天记录"
                    
                    # 提供清理方式选择
                    echo "请选择清理方式:"
                    echo "1. 清理楼层范围"
                    echo "2. 保留特定倍数楼层"
                    echo -n "选择 [1/2]: "
                    cleanup_choice=$(get_single_key)
                    echo "$cleanup_choice"
                    
                    if [ "$cleanup_choice" = "1" ]; then
                        # 楼层范围清理
                        echo -n "请输入要清理的楼层范围(如 \"10\" 或 \"5-20\"，输入\"全选\"表示全部楼层): "
                        read -r floor_range
                        
                        # 解析楼层范围
                        start_floor=0
                        end_floor=0
                        
                        if [[ "$floor_range" =~ ^[0-9]+$ ]]; then
                            # 单一楼层
                            start_floor=$floor_range
                            end_floor=$floor_range
                        elif [[ "$floor_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                            # 楼层范围
                            start_floor=${floor_range%-*}
                            end_floor=${floor_range#*-}
                        elif [ "$floor_range" = "全选" ]; then
                            # 全部楼层
                            start_floor=-999
                            end_floor=-999
                        else
                            echo "无效的楼层范围，操作已取消"
                            press_any_key
                            continue
                        fi
                        
                        # 处理每个选中的角色目录下的所有聊天记录
                        for char_dir in "${selected_char_dirs[@]}"; do
                            echo "处理角色目录: $(basename "$char_dir")"
                            
                            # 遍历该角色目录下的所有聊天记录目录
                            while IFS= read -r chat_dir; do
                                if [ -d "$chat_dir" ]; then
                                    # 获取楼层范围
                                    read floor_min floor_max < <(get_floor_range "$chat_dir")
                                    
                                    # 全选
                                    local actual_start=$start_floor
                                    local actual_end=$end_floor
                                    
                                    if [ "$actual_start" -eq -999 ]; then
                                        actual_start=$floor_min
                                    fi
                                    
                                    if [ "$actual_end" -eq -999 ]; then
                                        actual_end=$floor_max
                                    fi
                                    
                                    # 检查目录文件数
                                    total_files=$(count_files_in_dir "$chat_dir")
                                    
                                    # 如果目录为空，跳过
                                    if [ "$total_files" -eq 0 ]; then
                                        echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                                        continue
                                    elif [ "$total_files" -eq 1 ]; then
                                        # 如果只有一个文件，询问是否删除
                                        echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                                        echo -n "是否删除？(y/n): "
                                        read -r confirm
                                        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                            # 删除唯一的文件
                                            for file in "$chat_dir"/*楼*.jsonl; do
                                                [ -f "$file" ] || continue
                                                rm "$file"
                                                echo "删除文件: $file"
                                            done
                                            echo "文件已删除"
                                        else
                                            echo "保留唯一文件，跳过清理"
                                        fi
                                        continue
                                    fi
                                    
                                    # 检查是否会清空目录
                                    will_empty=$(will_dir_be_empty "$chat_dir" "$actual_start" "$actual_end")
                                    
                                    if [ "$will_empty" -eq 1 ]; then
                                        echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                                        echo "1. 继续清理文件"
                                        echo "2. 直接删除整个目录"
                                        echo "3. 跳过此目录"
                                        echo -n "选择操作(1-3): "
                                        read -r choice
                                        
                                        case "$choice" in
                                            1)
                                                cleanup_range "$chat_dir" "$actual_start" "$actual_end"
                                                ;;
                                            2)
                                                echo -n "确认删除整个目录? (y/n): "
                                                read -r confirm
                                                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                    delete_chat_dir "$chat_dir"
                                                    echo "已删除整个目录 $(basename "$chat_dir")"
                                                else
                                                    echo "取消删除操作"
                                                fi
                                                ;;
                                            *)
                                                echo "跳过目录 $(basename "$chat_dir")"
                                                ;;
                                        esac
                                    else
                                        cleanup_range "$chat_dir" "$actual_start" "$actual_end"
                                    fi
                                fi
                            done < <(find "$char_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                        done
                    else
                        # 保留特定倍数楼层的清理
                        echo -e "保留哪个倍数的楼层？(默认\033[33m${SAVE_INTERVAL}\033[0m，直接回车使用默认值): "
                        read -r multiple
                        
                        if [[ ! $multiple =~ ^[0-9]+$ ]]; then
                            multiple=$SAVE_INTERVAL
                            echo "使用默认倍数: $multiple"
                        fi
                        
                        # 处理每个选中的角色目录下的所有聊天记录
                        for char_dir in "${selected_char_dirs[@]}"; do
                            echo "处理角色目录: $(basename "$char_dir")"
                            
                            # 遍历该角色目录下的所有聊天记录目录
                            while IFS= read -r chat_dir; do
                                if [ -d "$chat_dir" ]; then
                                    # 检查目录文件数
                                    total_files=$(count_files_in_dir "$chat_dir")
                                    
                                    # 如果目录为空，跳过
                                    if [ "$total_files" -eq 0 ]; then
                                        echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                                        continue
                                    elif [ "$total_files" -eq 1 ]; then
                                        # 如果只有一个文件，询问是否删除
                                        echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                                        echo -n "是否删除？(y/n): "
                                        read -r confirm
                                        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                            # 删除唯一的文件
                                            for file in "$chat_dir"/*楼*.jsonl; do
                                                [ -f "$file" ] || continue
                                                rm "$file"
                                                echo "删除文件: $file"
                                            done
                                            echo "文件已删除"
                                        else
                                            echo "保留唯一文件，跳过清理"
                                        fi
                                        continue
                                    fi
                                    
                                    # 检查是否会清空目录
                                    will_empty=$(will_dir_be_empty_by_multiple "$chat_dir" "$multiple")
                                    
                                    if [ "$will_empty" -eq 1 ]; then
                                        echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                                        echo "1. 继续清理文件"
                                        echo "2. 直接删除整个目录"
                                        echo "3. 跳过此目录"
                                        echo -n "选择操作(1-3): "
                                        read -r choice
                                        
                                        case "$choice" in
                                            1)
                                                cleanup_by_multiple "$chat_dir" "$multiple"
                                                ;;
                                            2)
                                                echo -n "确认删除整个目录? (y/n): "
                                                read -r confirm
                                                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                    delete_chat_dir "$chat_dir"
                                                    echo "已删除整个目录 $(basename "$chat_dir")"
                                                else
                                                    echo "取消删除操作"
                                                fi
                                                ;;
                                            *)
                                                echo "跳过目录 $(basename "$chat_dir")"
                                                ;;
                                        esac
                                    else
                                        cleanup_by_multiple "$chat_dir" "$multiple"
                                    fi
                                fi
                            done < <(find "$char_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                        done
                    fi
                    
                    press_any_key
                    continue
                fi
                
                # 单选时继续显示下一级的目录
                selected_char_dir="${selected_char_dirs[0]}"
                
                # 再次询问排序方式
                ask_sort_method
                
                # 显示二级目录(聊天记录)
                echo "选择聊天记录目录:"
                
                chat_dirs=()
                i=0
                
                while IFS= read -r dir; do
                    if [ -d "$dir" ]; then
                        # 检查目录下是否有文件
                        if [ -n "$(find "$dir" -type f)" ]; then
                            chat_dirs+=("$dir")
                            echo "$((++i)) - $(basename "$dir")"
                        fi
                    fi
                done < <(find "$selected_char_dir" -mindepth 1 -maxdepth 1 -type d | sort)
                
                if [ ${#chat_dirs[@]} -eq 0 ]; then
                    echo "没有聊天记录目录或目录路径有误: $selected_char_dir"
                    press_any_key
                    continue
                fi
                
                # 用户选择聊天记录目录
                echo -n "选择目录编号(按回车确认): "
                read -r choice
                
                if [[ ! $choice =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#chat_dirs[@]} ]]; then
                    echo "无效选择"
                    press_any_key
                    continue
                fi
                
                selected_chat_dir="${chat_dirs[$((choice-1))]}"
                
                # 提供清理方式选择
                read floor_min floor_max < <(get_floor_range "$selected_chat_dir")
                echo "楼层范围: ${floor_min}楼 - ${floor_max}楼"
                echo "文件总数: $(count_files_in_dir "$selected_chat_dir") 个"

                # 检查目录文件数
                total_files=$(count_files_in_dir "$selected_chat_dir")
                if [ "$total_files" -eq 0 ]; then
                    echo "目录中没有文件，无需清理"
                    press_any_key
                    continue
                fi

                echo "请选择清理方式:"
                echo "1. 清理楼层范围"
                echo "2. 保留特定倍数楼层"
                echo -n "选择 [1/2] (直接回车取消): "
                cleanup_choice=$(get_single_key)
                echo "$cleanup_choice"
                
                if [ "$cleanup_choice" = "1" ]; then
                    # 楼层范围清理
                    echo -n "请输入要清理的楼层范围(如 \"10\" 或 \"5-20\"，输入\"全选\"表示全部楼层): "
                    read -r floor_range
                    
                    # 解析楼层范围
                    start_floor=0
                    end_floor=0
                    
                    if [[ "$floor_range" =~ ^[0-9]+$ ]]; then
                        # 单一楼层
                        start_floor=$floor_range
                        end_floor=$floor_range
                    elif [[ "$floor_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                        # 楼层范围
                        start_floor=${floor_range%-*}
                        end_floor=${floor_range#*-}
                    elif [ "$floor_range" = "全选" ]; then
                        # 全部楼层
                        start_floor=-999
                        end_floor=-999
                    else
                        echo "无效的楼层范围，操作已取消"
                        press_any_key
                        continue
                    fi
                    
                    # 全选
                    local actual_start=$start_floor
                    local actual_end=$end_floor
                    
                    if [ "$actual_start" -eq -999 ]; then
                        actual_start=$floor_min
                    fi
                    
                    if [ "$actual_end" -eq -999 ]; then
                        actual_end=$floor_max
                    fi
                    
                    # 检查目录文件数
                    total_files=$(count_files_in_dir "$selected_chat_dir")
                    
                    # 如果目录为空，跳过
                    if [ "$total_files" -eq 0 ]; then
                        echo "目录中没有文件，跳过清理"
                        press_any_key
                        continue
                    elif [ "$total_files" -eq 1 ]; then
                        # 如果只有一个文件，询问是否删除
                        echo "警告：该目录只有一个文件。"
                        echo -n "是否删除？(y/n): "
                        read -r confirm
                        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                            # 删除唯一的文件
                            for file in "$selected_chat_dir"/*楼*.jsonl; do
                                [ -f "$file" ] || continue
                                rm "$file"
                                echo "删除文件: $file"
                            done
                            echo "文件已删除"
                        else
                            echo "保留唯一文件，跳过清理"
                        fi
                        press_any_key
                        continue
                    fi
                    
                    # 检查是否会清空目录
                    will_empty=$(will_dir_be_empty "$selected_chat_dir" "$actual_start" "$actual_end")
                    
                    if [ "$will_empty" -eq 1 ]; then
                        echo "警告：清理将清空或几乎清空该目录"
                        echo "1. 继续清理文件"
                        echo "2. 直接删除整个目录"
                        echo "3. 取消操作"
                        echo -n "选择操作(1-3): "
                        read -r choice
                        
                        case "$choice" in
                            1)
                                cleanup_range "$selected_chat_dir" "$actual_start" "$actual_end"
                                ;;
                            2)
                                echo -n "确认删除整个目录? (y/n): "
                                read -r confirm
                                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                    delete_chat_dir "$selected_chat_dir"
                                    echo "已删除整个目录"
                                else
                                    echo "取消删除操作"
                                fi
                                ;;
                            *)
                                echo "操作已取消"
                                ;;
                        esac
                    else
                        cleanup_range "$selected_chat_dir" "$actual_start" "$actual_end"
                    fi
                elif [ "$cleanup_choice" = "2" ]; then
                    # 保留特定倍数楼层的清理
                    echo -e "保留哪个倍数的楼层？(默认\033[33m${SAVE_INTERVAL}\033[0m，直接回车使用默认值): "
                    read -r multiple
                    
                    if [[ ! $multiple =~ ^[0-9]+$ ]]; then
                        multiple=$SAVE_INTERVAL
                        echo "使用默认倍数: $multiple"
                    fi
                    
                    # 处理每个选中的聊天记录目录
                    for chat_dir in "${selected_chat_dirs[@]}"; do
                        # 检查目录文件数
                        total_files=$(count_files_in_dir "$chat_dir")
                        
                        # 如果目录为空，跳过
                        if [ "$total_files" -eq 0 ]; then
                            echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                            continue
                        elif [ "$total_files" -eq 1 ]; then
                            # 如果只有一个文件，询问是否删除
                            echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                            echo -n "是否删除？(y/n): "
                            read -r confirm
                            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                # 删除唯一的文件
                                for file in "$chat_dir"/*楼*.jsonl; do
                                    [ -f "$file" ] || continue
                                    rm "$file"
                                    echo "删除文件: $file"
                                done
                                echo "文件已删除"
                            else
                                echo "保留唯一文件，跳过清理"
                            fi
                            continue
                        fi
                        
                        # 检查是否会清空目录
                        will_empty=$(will_dir_be_empty_by_multiple "$chat_dir" "$multiple")
                        
                        if [ "$will_empty" -eq 1 ]; then
                            echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                            echo "1. 继续清理文件"
                            echo "2. 直接删除整个目录"
                            echo "3. 跳过此目录"
                            echo -n "选择操作(1-3): "
                            read -r choice
                            
                            case "$choice" in
                                1)
                                    cleanup_by_multiple "$chat_dir" "$multiple"
                                    ;;
                                2)
                                    echo -n "确认删除整个目录? (y/n): "
                                    read -r confirm
                                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                        delete_chat_dir "$chat_dir"
                                        echo "已删除整个目录 $(basename "$chat_dir")"
                                    else
                                        echo "取消删除操作"
                                    fi
                                    ;;
                                3)
                                    echo "已取消，返回上一级菜单"
                                    press_any_key
                                    continue
                                    ;;
                                *)
                                    echo "跳过目录 $(basename "$chat_dir")"
                                    ;;
                            esac
                        else
                            cleanup_by_multiple "$chat_dir" "$multiple"
                        fi
                    done
                elif [ -z "$cleanup_choice" ]; then
                    echo "已取消，返回上一级菜单"
                    press_any_key
                    continue
                else
                    echo "无效选择，请输入1或2"
                    read -r cleanup_choice
                    continue
                fi
                press_any_key
                ;;
            3)
                echo -n "输入角色名称(按回车确认): "
                read -r char_name
                if [ -n "$char_name" ]; then
                    # 只查找一级目录中匹配角色名的目录
                    char_dirs=()
                    
                    while IFS= read -r dir; do
                        if [ -d "$dir" ]; then
                            char_dirs+=("$dir")
                        fi
                    done < <(find "$SAVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -name "*${char_name}*")
                    
                    if [ ${#char_dirs[@]} -eq 0 ]; then
                        echo "未找到角色 '$char_name' 的目录"
                        press_any_key
                        continue
                    fi
                    
                    # 询问排序方式
                    ask_sort_method
                    
                    # 排序目录 - 使用NULL分隔符读取结果，避免空格问题
                    sorted_char_dirs=()
                    while IFS= read -r -d $'\0' dir; do
                        sorted_char_dirs+=("$dir")
                    done < <(sort_directories "${char_dirs[@]}")
                    
                    echo "找到 ${#sorted_char_dirs[@]} 个匹配目录:"
                    
                    # 显示排序后的目录
                    i=0
                    for dir in "${sorted_char_dirs[@]}"; do
                        echo "$((++i)) - $(basename "$dir")"
                    done
                    
                    # 用户选择
                    echo -n "选择目录编号(可用逗号或空格分隔多选，按回车确认，按s切换排序顺序): "
                    read -r choice
                    
                    # 检查是否是切换排序顺序
                    if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
                        if [ "$SORT_ORDER" = "asc" ]; then
                            SORT_ORDER="desc"
                            echo "已切换为降序排列："
                        else
                            SORT_ORDER="asc"
                            echo "已切换为升序排列："
                        fi
                        save_config
                        
                        # 直接重新排序并显示，不清屏
                        sorted_char_dirs=()
                        while IFS= read -r -d $'\0' dir; do
                            sorted_char_dirs+=("$dir")
                        done < <(sort_directories "${char_dirs[@]}")
                        
                        i=0
                        for dir in "${sorted_char_dirs[@]}"; do
                            echo "$((++i)) - $(basename "$dir")"
                        done
                        
                        echo -n "选择目录编号(可用逗号或空格分隔多选，按回车确认，按s切换排序顺序): "
                        read -r choice
                        
                        # 继续检查其他情况
                        if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
                            continue
                        fi
                    fi
                    
                    # 处理多选
                    selected_indices=($(process_range_selection "$choice" ${#sorted_char_dirs[@]}))
                    
                    if [ ${#selected_indices[@]} -eq 0 ]; then
                        echo "无效选择"
                        press_any_key
                        continue
                    fi
                    
                    # 获取选择的目录
                    selected_char_dirs=()
                    for idx in "${selected_indices[@]}"; do
                        selected_char_dirs+=("${sorted_char_dirs[$((idx-1))]}")
                    done
                    
                    # 如果是多选，直接处理所有子目录
                    if [ ${#selected_char_dirs[@]} -gt 1 ]; then
                        echo "您选择了多个角色目录，将处理其下所有聊天记录"
                        
                        # 提供清理方式选择
                        echo "请选择清理方式:"
                        echo "1. 清理楼层范围"
                        echo "2. 保留特定倍数楼层"
                        echo -n "选择 [1/2]: "
                        cleanup_choice=$(get_single_key)
                        echo "$cleanup_choice"
                        
                        if [ "$cleanup_choice" = "1" ]; then
                            # 楼层范围清理
                            echo -n "请输入要清理的楼层范围(如 \"10\" 或 \"5-20\"，输入\"全选\"表示全部楼层): "
                            read -r floor_range
                            
                            # 解析楼层范围
                            start_floor=0
                            end_floor=0
                            
                            if [[ "$floor_range" =~ ^[0-9]+$ ]]; then
                                # 单一楼层
                                start_floor=$floor_range
                                end_floor=$floor_range
                            elif [[ "$floor_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                                # 楼层范围
                                start_floor=${floor_range%-*}
                                end_floor=${floor_range#*-}
                            elif [ "$floor_range" = "全选" ]; then
                                # 全部楼层
                                start_floor=-999
                                end_floor=-999
                            else
                                echo "无效的楼层范围，操作已取消"
                                press_any_key
                                continue
                            fi
                            
                            # 处理每个选中的角色目录下的所有聊天记录
                            for char_dir in "${selected_char_dirs[@]}"; do
                                echo "处理角色目录: $(basename "$char_dir")"
                                
                                # 遍历该角色目录下的所有聊天记录目录
                                while IFS= read -r chat_dir; do
                                    if [ -d "$chat_dir" ]; then
                                        # 获取楼层范围
                                        read floor_min floor_max < <(get_floor_range "$chat_dir")
                                        
                                        # 全选
                                        local actual_start=$start_floor
                                        local actual_end=$end_floor
                                        
                                        if [ "$actual_start" -eq -999 ]; then
                                            actual_start=$floor_min
                                        fi
                                        
                                        if [ "$actual_end" -eq -999 ]; then
                                            actual_end=$floor_max
                                        fi
                                        
                                        # 检查目录文件数
                                        total_files=$(count_files_in_dir "$chat_dir")
                                        
                                        # 如果目录为空，跳过
                                        if [ "$total_files" -eq 0 ]; then
                                            echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                                            continue
                                        elif [ "$total_files" -eq 1 ]; then
                                            # 如果只有一个文件，询问是否删除
                                            echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                                            echo -n "是否删除？(y/n): "
                                            read -r confirm
                                            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                # 删除唯一的文件
                                                for file in "$chat_dir"/*楼*.jsonl; do
                                                    [ -f "$file" ] || continue
                                                    rm "$file"
                                                    echo "删除文件: $file"
                                                done
                                                echo "文件已删除"
                                            else
                                                echo "保留唯一文件，跳过清理"
                                            fi
                                            continue
                                        fi
                                        
                                        # 检查是否会清空目录
                                        will_empty=$(will_dir_be_empty "$chat_dir" "$actual_start" "$actual_end")
                                        
                                        if [ "$will_empty" -eq 1 ]; then
                                            echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                                            echo "1. 继续清理文件"
                                            echo "2. 直接删除整个目录"
                                            echo "3. 跳过此目录"
                                            echo -n "选择操作(1-3): "
                                            read -r choice
                                            
                                            case "$choice" in
                                                1)
                                                    cleanup_range "$chat_dir" "$actual_start" "$actual_end"
                                                    ;;
                                                2)
                                                    echo -n "确认删除整个目录? (y/n): "
                                                    read -r confirm
                                                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                        delete_chat_dir "$chat_dir"
                                                        echo "已删除整个目录 $(basename "$chat_dir")"
                                                    else
                                                        echo "取消删除操作"
                                                    fi
                                                    ;;
                                                *)
                                                    echo "跳过目录 $(basename "$chat_dir")"
                                                    ;;
                                            esac
                                        else
                                            cleanup_range "$chat_dir" "$actual_start" "$actual_end"
                                        fi
                                    fi
                                done < <(find "$char_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                            done
                        else
                            # 保留特定倍数楼层的清理
                            echo -e "保留哪个倍数的楼层？(默认\033[33m${SAVE_INTERVAL}\033[0m，直接回车使用默认值): "
                            read -r multiple
                            
                            if [[ ! $multiple =~ ^[0-9]+$ ]]; then
                                multiple=$SAVE_INTERVAL
                                echo "使用默认倍数: $multiple"
                            fi
                            
                            # 处理每个选中的角色目录下的所有聊天记录
                            for char_dir in "${selected_char_dirs[@]}"; do
                                echo "处理角色目录: $(basename "$char_dir")"
                                
                                # 遍历该角色目录下的所有聊天记录目录
                                while IFS= read -r chat_dir; do
                                    if [ -d "$chat_dir" ]; then
                                        # 检查目录文件数
                                        total_files=$(count_files_in_dir "$chat_dir")
                                        
                                        # 如果目录为空，跳过
                                        if [ "$total_files" -eq 0 ]; then
                                            echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                                            continue
                                        elif [ "$total_files" -eq 1 ]; then
                                            # 如果只有一个文件，询问是否删除
                                            echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                                            echo -n "是否删除？(y/n): "
                                            read -r confirm
                                            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                # 删除唯一的文件
                                                for file in "$chat_dir"/*楼*.jsonl; do
                                                    [ -f "$file" ] || continue
                                                    rm "$file"
                                                    echo "删除文件: $file"
                                                done
                                                echo "文件已删除"
                                            else
                                                echo "保留唯一文件，跳过清理"
                                            fi
                                            continue
                                        fi
                                        
                                        # 检查是否会清空目录
                                        will_empty=$(will_dir_be_empty_by_multiple "$chat_dir" "$multiple")
                                        
                                        if [ "$will_empty" -eq 1 ]; then
                                            echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                                            echo "1. 继续清理文件"
                                            echo "2. 直接删除整个目录"
                                            echo "3. 跳过此目录"
                                            echo -n "选择操作(1-3): "
                                            read -r choice
                                            
                                            case "$choice" in
                                                1)
                                                    cleanup_by_multiple "$chat_dir" "$multiple"
                                                    ;;
                                                2)
                                                    echo -n "确认删除整个目录? (y/n): "
                                                    read -r confirm
                                                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                        delete_chat_dir "$chat_dir"
                                                        echo "已删除整个目录 $(basename "$chat_dir")"
                                                    else
                                                        echo "取消删除操作"
                                                    fi
                                                    ;;
                                                *)
                                                    echo "跳过目录 $(basename "$chat_dir")"
                                                    ;;
                                            esac
                                        else
                                            cleanup_by_multiple "$chat_dir" "$multiple"
                                        fi
                                    fi
                                done < <(find "$char_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                            done
                        fi
                        
                        press_any_key
                        continue
                    fi
                    
                    # 单选时继续显示下一级的目录
                    selected_char_dir="${selected_char_dirs[0]}"
                    
                    # 再次询问排序方式
                    ask_sort_method
                    
                    # 显示二级目录(聊天记录)
                    echo "选择聊天记录目录:"
                    echo "提示: 可以使用逗号或空格分隔多个编号进行多选"
                    echo "      也可以输入范围 (如1-5) 或输入'全选'选择所有目录"
                    
                    chat_dirs=()
                    i=0
                    
                    while IFS= read -r dir; do
                        if [ -d "$dir" ]; then
                            # 检查目录下是否有文件
                            if [ -n "$(find "$dir" -type f)" ]; then
                                chat_dirs+=("$dir")
                                echo "$((++i)) - $(basename "$dir")"
                            fi
                        fi
                    done < <(find "$selected_char_dir" -mindepth 1 -maxdepth 1 -type d | sort)
                    
                    if [ ${#chat_dirs[@]} -eq 0 ]; then
                        echo "没有聊天记录目录"
                        press_any_key
                        continue
                    fi
                    
                    # 用户选择聊天记录目录
                    echo -n "选择目录编号(按回车确认): "
                    read -r choice
                    
                    # 处理多选
                    selected_indices=($(process_range_selection "$choice" ${#chat_dirs[@]}))
                    
                    if [ ${#selected_indices[@]} -eq 0 ]; then
                        echo "无效选择"
                        press_any_key
                        continue
                    fi
                    
                    # 获取选择的目录
                    selected_chat_dirs=()
                    for idx in "${selected_indices[@]}"; do
                        selected_chat_dirs+=("${chat_dirs[$((idx-1))]}")
                    done
                    
                    # 如果是多选，直接处理所有子目录
                    if [ ${#selected_chat_dirs[@]} -gt 1 ]; then
                        echo "您选择了${#selected_chat_dirs[@]}个聊天记录目录，将一并处理"
                        
                        # 提供清理方式选择
                        echo "请选择清理方式:"
                        echo "1. 清理楼层范围"
                        echo "2. 保留特定倍数楼层"
                        echo -n "选择 [1/2]: "
                        cleanup_choice=$(get_single_key)
                        echo "$cleanup_choice"
                        
                        if [ "$cleanup_choice" = "1" ]; then
                            # 楼层范围清理
                            echo -n "请输入要清理的楼层范围(如 \"10\" 或 \"5-20\"，输入\"全选\"表示全部楼层): "
                            read -r floor_range
                            
                            # 解析楼层范围
                            start_floor=0
                            end_floor=0
                            
                            if [[ "$floor_range" =~ ^[0-9]+$ ]]; then
                                # 单一楼层
                                start_floor=$floor_range
                                end_floor=$floor_range
                            elif [[ "$floor_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                                # 楼层范围
                                start_floor=${floor_range%-*}
                                end_floor=${floor_range#*-}
                            elif [ "$floor_range" = "全选" ]; then
                                # 全部楼层
                                start_floor=-999
                                end_floor=-999
                            else
                                echo "无效的楼层范围，操作已取消"
                                press_any_key
                                continue
                            fi
                            
                            # 处理每个选中的聊天记录目录
                            for chat_dir in "${selected_chat_dirs[@]}"; do
                                # 获取楼层范围
                                read floor_min floor_max < <(get_floor_range "$chat_dir")
                                echo "目录 $(basename "$chat_dir") 楼层范围: ${floor_min}楼 - ${floor_max}楼"
                                
                                # 全选
                                local actual_start=$start_floor
                                local actual_end=$end_floor
                                
                                if [ "$actual_start" -eq -999 ]; then
                                    actual_start=$floor_min
                                fi
                                
                                if [ "$actual_end" -eq -999 ]; then
                                    actual_end=$floor_max
                                fi
                                
                                # 检查目录文件数
                                total_files=$(count_files_in_dir "$chat_dir")
                                
                                # 如果目录为空，跳过
                                if [ "$total_files" -eq 0 ]; then
                                    echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                                    continue
                                elif [ "$total_files" -eq 1 ]; then
                                    # 如果只有一个文件，询问是否删除
                                    echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                                    echo -n "是否删除？(y/n): "
                                    read -r confirm
                                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                        # 删除唯一的文件
                                        for file in "$chat_dir"/*楼*.jsonl; do
                                            [ -f "$file" ] || continue
                                            rm "$file"
                                            echo "删除文件: $file"
                                        done
                                        echo "文件已删除"
                                    else
                                        echo "保留唯一文件，跳过清理"
                                    fi
                                    continue
                                fi
                                
                                # 检查是否会清空目录
                                will_empty=$(will_dir_be_empty "$chat_dir" "$actual_start" "$actual_end")
                                
                                if [ "$will_empty" -eq 1 ]; then
                                    echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                                    echo "1. 继续清理文件"
                                    echo "2. 直接删除整个目录"
                                    echo "3. 跳过此目录"
                                    echo -n "选择操作(1-3): "
                                    read -r choice
                                    
                                    case "$choice" in
                                        1)
                                            cleanup_range "$chat_dir" "$actual_start" "$actual_end"
                                            ;;
                                        2)
                                            echo -n "确认删除整个目录? (y/n): "
                                            read -r confirm
                                            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                delete_chat_dir "$chat_dir"
                                                echo "已删除整个目录 $(basename "$chat_dir")"
                                            else
                                                echo "取消删除操作"
                                            fi
                                            ;;
                                        *)
                                            echo "跳过目录 $(basename "$chat_dir")"
                                            ;;
                                    esac
                                else
                                    cleanup_range "$chat_dir" "$actual_start" "$actual_end"
                                fi
                            done
                        else
                            # 保留特定倍数楼层的清理
                            echo -e "保留哪个倍数的楼层？(默认\033[33m${SAVE_INTERVAL}\033[0m，直接回车使用默认值): "
                            read -r multiple
                            
                            if [[ ! $multiple =~ ^[0-9]+$ ]]; then
                                multiple=$SAVE_INTERVAL
                                echo "使用默认倍数: $multiple"
                            fi
                            
                            # 处理每个选中的聊天记录目录
                            for chat_dir in "${selected_chat_dirs[@]}"; do
                                # 检查目录文件数
                                total_files=$(count_files_in_dir "$chat_dir")
                                
                                # 如果目录为空，跳过
                                if [ "$total_files" -eq 0 ]; then
                                    echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                                    continue
                                elif [ "$total_files" -eq 1 ]; then
                                    # 如果只有一个文件，询问是否删除
                                    echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                                    echo -n "是否删除？(y/n): "
                                    read -r confirm
                                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                        # 删除唯一的文件
                                        for file in "$chat_dir"/*楼*.jsonl; do
                                            [ -f "$file" ] || continue
                                            rm "$file"
                                            echo "删除文件: $file"
                                        done
                                        echo "文件已删除"
                                    else
                                        echo "保留唯一文件，跳过清理"
                                    fi
                                    continue
                                fi
                                
                                # 检查是否会清空目录
                                will_empty=$(will_dir_be_empty_by_multiple "$chat_dir" "$multiple")
                                
                                if [ "$will_empty" -eq 1 ]; then
                                    echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                                    echo "1. 继续清理文件"
                                    echo "2. 直接删除整个目录"
                                    echo "3. 跳过此目录"
                                    echo -n "选择操作(1-3): "
                                    read -r choice
                                    
                                    case "$choice" in
                                        1)
                                            cleanup_by_multiple "$chat_dir" "$multiple"
                                            ;;
                                        2)
                                            echo -n "确认删除整个目录? (y/n): "
                                            read -r confirm
                                            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                delete_chat_dir "$chat_dir"
                                                echo "已删除整个目录 $(basename "$chat_dir")"
                                            else
                                                echo "取消删除操作"
                                            fi
                                            ;;
                                        3)
                                            echo "已取消，返回上一级菜单"
                                            press_any_key
                                            continue
                                            ;;
                                        *)
                                            echo "跳过目录 $(basename "$chat_dir")"
                                            ;;
                                    esac
                                else
                                    cleanup_by_multiple "$chat_dir" "$multiple"
                                fi
                            done
                        fi
                    else
                        # 单选情况
                        selected_chat_dir="${selected_chat_dirs[0]}"

                        # 提供清理方式选择
                        read floor_min floor_max < <(get_floor_range "$selected_chat_dir")
                        echo "楼层范围: ${floor_min}楼 - ${floor_max}楼"
                        echo "文件总数: $(count_files_in_dir "$selected_chat_dir") 个"

                        # 检查目录文件数
                        total_files=$(count_files_in_dir "$selected_chat_dir")
                        if [ "$total_files" -eq 0 ]; then
                            echo "目录中没有文件，无需清理"
                            press_any_key
                            continue
                        fi

                        echo "请选择清理方式:"
                        echo "1. 清理楼层范围"
                        echo "2. 保留特定倍数楼层"
                        echo -n "选择 [1/2] (直接回车取消): "
                        cleanup_choice=$(get_single_key)
                        echo "$cleanup_choice"
                        
                        if [ "$cleanup_choice" = "1" ]; then
                            # 楼层范围清理
                            echo -n "请输入要清理的楼层范围(如 \"10\" 或 \"5-20\"，输入\"全选\"表示全部楼层): "
                            read -r floor_range
                            
                            # 解析楼层范围
                            start_floor=0
                            end_floor=0
                            
                            if [[ "$floor_range" =~ ^[0-9]+$ ]]; then
                                # 单一楼层
                                start_floor=$floor_range
                                end_floor=$floor_range
                            elif [[ "$floor_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                                # 楼层范围
                                start_floor=${floor_range%-*}
                                end_floor=${floor_range#*-}
                            elif [ "$floor_range" = "全选" ]; then
                                # 全部楼层
                                start_floor=-999
                                end_floor=-999
                            else
                                echo "无效的楼层范围，操作已取消"
                                press_any_key
                                continue
                            fi
                            
                            
                            # 全选
                            local actual_start=$start_floor
                            local actual_end=$end_floor
                            
                            if [ "$actual_start" -eq -999 ]; then
                                actual_start=$floor_min
                            fi
                            
                            if [ "$actual_end" -eq -999 ]; then
                                actual_end=$floor_max
                            fi
                            
                            # 检查目录文件数
                            total_files=$(count_files_in_dir "$selected_chat_dir")
                            
                            # 如果目录为空，跳过
                            if [ "$total_files" -eq 0 ]; then
                                echo "目录中没有文件，跳过清理"
                                press_any_key
                                continue
                            elif [ "$total_files" -eq 1 ]; then
                                # 如果只有一个文件，询问是否删除
                                echo "警告：该目录只有一个文件。"
                                echo -n "是否删除？(y/n): "
                                read -r confirm
                                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                    # 删除唯一的文件
                                    for file in "$selected_chat_dir"/*楼*.jsonl; do
                                        [ -f "$file" ] || continue
                                        rm "$file"
                                        echo "删除文件: $file"
                                    done
                                    echo "文件已删除"
                                else
                                    echo "保留唯一文件，跳过清理"
                                fi
                                press_any_key
                                continue
                            fi
                            
                            # 检查是否会清空目录
                            will_empty=$(will_dir_be_empty "$selected_chat_dir" "$actual_start" "$actual_end")
                            
                            if [ "$will_empty" -eq 1 ]; then
                                echo "警告：清理将清空或几乎清空该目录"
                                echo "1. 继续清理文件"
                                echo "2. 直接删除整个目录"
                                echo "3. 取消操作"
                                echo -n "选择操作(1-3): "
                                read -r choice
                                
                                case "$choice" in
                                    1)
                                        cleanup_range "$selected_chat_dir" "$actual_start" "$actual_end"
                                        ;;
                                    2)
                                        echo -n "确认删除整个目录? (y/n): "
                                        read -r confirm
                                        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                            delete_chat_dir "$selected_chat_dir"
                                            echo "已删除整个目录"
                                        else
                                            echo "取消删除操作"
                                        fi
                                        ;;
                                    *)
                                        echo "操作已取消"
                                        ;;
                                esac
                            else
                                cleanup_range "$selected_chat_dir" "$actual_start" "$actual_end"
                            fi
                        elif [ "$cleanup_choice" = "2" ]; then
                            # 保留特定倍数楼层的清理
                            echo -e "保留哪个倍数的楼层？(默认\033[33m${SAVE_INTERVAL}\033[0m，直接回车使用默认值): "
                            read -r multiple
                            
                            if [[ ! $multiple =~ ^[0-9]+$ ]]; then
                                multiple=$SAVE_INTERVAL
                                echo "使用默认倍数: $multiple"
                            fi
                            
                            # 处理每个选中的聊天记录目录
                            for chat_dir in "${selected_chat_dirs[@]}"; do
                                # 检查目录文件数
                                total_files=$(count_files_in_dir "$chat_dir")
                                
                                # 如果目录为空，跳过
                                if [ "$total_files" -eq 0 ]; then
                                    echo "目录 $(basename "$chat_dir") 中没有文件，跳过清理"
                                    continue
                                elif [ "$total_files" -eq 1 ]; then
                                    # 如果只有一个文件，询问是否删除
                                    echo "警告：目录 $(basename "$chat_dir") 只有一个文件。"
                                    echo -n "是否删除？(y/n): "
                                    read -r confirm
                                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                        # 删除唯一的文件
                                        for file in "$chat_dir"/*楼*.jsonl; do
                                            [ -f "$file" ] || continue
                                            rm "$file"
                                            echo "删除文件: $file"
                                        done
                                        echo "文件已删除"
                                    else
                                        echo "保留唯一文件，跳过清理"
                                    fi
                                    continue
                                fi
                                
                                # 检查是否会清空目录
                                will_empty=$(will_dir_be_empty_by_multiple "$chat_dir" "$multiple")
                                
                                if [ "$will_empty" -eq 1 ]; then
                                    echo "警告：清理 $(basename "$chat_dir") 将清空或几乎清空该目录"
                                    echo "1. 继续清理文件"
                                    echo "2. 直接删除整个目录"
                                    echo "3. 跳过此目录"
                                    echo -n "选择操作(1-3): "
                                    read -r choice
                                    
                                    case "$choice" in
                                        1)
                                            cleanup_by_multiple "$chat_dir" "$multiple"
                                            ;;
                                        2)
                                            echo -n "确认删除整个目录? (y/n): "
                                            read -r confirm
                                            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                                                delete_chat_dir "$chat_dir"
                                                echo "已删除整个目录 $(basename "$chat_dir")"
                                            else
                                                echo "取消删除操作"
                                            fi
                                            ;;
                                        3)
                                            echo "已取消，返回上一级菜单"
                                            press_any_key
                                            continue
                                            ;;
                                        *)
                                            echo "跳过目录 $(basename "$chat_dir")"
                                            ;;
                                    esac
                                else
                                    cleanup_by_multiple "$chat_dir" "$multiple"
                                fi
                            done
                        elif [ -z "$cleanup_choice" ]; then
                            echo "已取消，返回上一级菜单"
                            press_any_key
                            continue
                        else
                            echo "无效选择，请输入1或2"
                            read -r cleanup_choice
                            continue
                        fi
                    fi
                fi
                press_any_key
                ;;
            4)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}
# 导入聊天记录进酒馆功能
import_chat_records() {
    clear
    echo "====== 导入聊天记录进酒馆 ======"
    
    # 确认源目录存在
    if [ ! -d "$SOURCE_DIR" ]; then
        echo "错误：酒馆聊天记录目录不存在: $SOURCE_DIR"
        echo "请确保SillyTavern安装正确且路径设置正确。"
        press_any_key
        return
    fi
    
    # 检查备份目录是否存在
    if [ ! -d "$SAVE_BASE_DIR" ]; then
        echo "错误：备份目录不存在: $SAVE_BASE_DIR"
        echo "请先使用存档功能创建备份。"
        press_any_key
        return
    fi
    
    # 查找所有角色目录
    local char_dirs=()
    mapfile -t char_dirs < <(find "$SAVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    
    if [ ${#char_dirs[@]} -eq 0 ]; then
        echo "未找到任何角色目录。请先使用存档功能创建备份。"
        press_any_key
        return
    fi
    
    # 要求输入角色名进行搜索
    local search_term=""
    local filtered_char_dirs=()
    while true; do
        echo -n "请输入要导入的角色名（支持模糊搜索，直接回车取消）："
        read -r search_term
        
        # 如果直接回车，取消操作
        if [ -z "$search_term" ]; then
            echo "已取消导入操作"
            press_any_key
            return
        fi
        
        # 过滤角色目录
        filtered_char_dirs=()
        for dir in "${char_dirs[@]}"; do
            local char_name=$(basename "$dir")
            if [[ "$char_name" == *"$search_term"* ]]; then
                filtered_char_dirs+=("$dir")
            fi
        done
        
        # 显示匹配结果
        if [ ${#filtered_char_dirs[@]} -eq 0 ]; then
            echo "未找到匹配的角色，请重新输入或按回车取消。"
        else
            break
        fi
    done
    
    # 显示匹配的角色列表供选择
    echo ""
    echo "找到以下匹配的角色："
    for i in "${!filtered_char_dirs[@]}"; do
        local char_name=$(basename "${filtered_char_dirs[$i]}")
        echo "$((i+1)). $char_name"
    done
    
    # 选择角色目录
    local selected_char_index=0
    while true; do
        echo -n "请输入角色序号 (1-${#filtered_char_dirs[@]})："
        read -r selected_char_index
        
        # 验证输入
        if [ -z "$selected_char_index" ]; then
            echo "已取消导入操作"
            press_any_key
            return
        elif [[ ! "$selected_char_index" =~ ^[0-9]+$ ]] || [ "$selected_char_index" -lt 1 ] || [ "$selected_char_index" -gt ${#filtered_char_dirs[@]} ]; then
            echo "无效的序号，请重新输入。"
        else
            break
        fi
    done
    
    # 获取选择的角色目录
    local selected_char_dir="${filtered_char_dirs[$((selected_char_index-1))]}"
    local char_name=$(basename "$selected_char_dir")
    echo "已选择角色: $char_name"
    
    # 查找该角色下的所有聊天记录目录
    local chat_dirs=()
    mapfile -t chat_dirs < <(find "$selected_char_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    
    if [ ${#chat_dirs[@]} -eq 0 ]; then
        echo "该角色下未找到任何聊天记录或目录路径有误: $selected_char_dir"
        press_any_key
        return
    fi
    
    # 显示聊天记录列表供选择
    echo ""
    echo "找到以下聊天记录："
    for i in "${!chat_dirs[@]}"; do
        local chat_name=$(basename "${chat_dirs[$i]}")
        echo "$((i+1)). $chat_name"
    done
    
    # 选择聊天记录
    local selected_chat_index=0
    while true; do
        echo -n "请输入聊天记录序号 (1-${#chat_dirs[@]})："
        read -r selected_chat_index
        
        # 验证输入
        if [ -z "$selected_chat_index" ]; then
            echo "已取消导入操作"
            press_any_key
            return
        elif [[ ! "$selected_chat_index" =~ ^[0-9]+$ ]] || [ "$selected_chat_index" -lt 1 ] || [ "$selected_chat_index" -gt ${#chat_dirs[@]} ]; then
            echo "无效的序号，请重新输入。"
        else
            break
        fi
    done
    
    # 获取选择的聊天记录目录
    local selected_chat_dir="${chat_dirs[$((selected_chat_index-1))]}"
    local chat_name=$(basename "$selected_chat_dir")
    echo "已选择聊天记录: $chat_name"
    
    # 查找该聊天记录下的所有楼层文件
    local floor_files=()
    # 查找jsonl和xz文件
    mapfile -t floor_files < <(find_chat_files "$selected_chat_dir")
    
    if [ ${#floor_files[@]} -eq 0 ]; then
        echo "该聊天记录下未找到任何楼层文件。"
        press_any_key
        return
    fi
    
    # 解析楼层数字
    local floor_numbers=()
    for file in "${floor_files[@]}"; do
        local basename=$(basename "$file")
        local floor_num=$(echo "$basename" | grep -oE '^[0-9]+' | head -1)
        if [ -n "$floor_num" ]; then
            floor_numbers+=("$floor_num")
        fi
    done
    
    # 排序楼层数字
    IFS=$'\n' floor_numbers=($(sort -n <<<"${floor_numbers[*]}"))
    unset IFS
    
    # 显示楼层范围和文件数量
    local min_floor=${floor_numbers[0]}
    local max_floor=${floor_numbers[-1]}
    echo ""
    echo "楼层范围: $min_floor - $max_floor"
    echo "文件总数: ${#floor_files[@]}"
    echo ""
    
    # 选择导入模式
    local import_mode=0
    while true; do
        echo -n "请选择导入模式 (1.导入最新楼层 (${max_floor} 楼), 2.导入指定楼层, 直接回车取消)："
        read -r import_mode
        
        if [ -z "$import_mode" ]; then
            echo "已取消导入操作"
            press_any_key
            return
        elif [ "$import_mode" = "1" ]; then
            # 导入最新楼层
            local target_floor="$max_floor"
            break
        elif [ "$import_mode" = "2" ]; then
            # 导入指定楼层
            echo -n "请输入要导入的楼层数："
            read -r target_floor
            
            # 验证楼层是否存在
            local floor_exists=0
            for floor in "${floor_numbers[@]}"; do
                if [ "$floor" = "$target_floor" ]; then
                    floor_exists=1
                    break
                fi
            done
            
            if [ "$floor_exists" -eq 1 ]; then
                break
            else
                echo "指定的楼层不存在，正在查找最接近的楼层..."
                
                # 找出最接近的3个楼层
                local closest_floors=()
                local floor_diffs=()
                
                for floor in "${floor_numbers[@]}"; do
                    local diff=$((floor > target_floor ? floor - target_floor : target_floor - floor))
                    floor_diffs+=("$diff:$floor")
                done
                
                # 排序差值
                IFS=$'\n' floor_diffs=($(sort -n <<<"${floor_diffs[*]}"))
                unset IFS
                
                # 提取前3个最接近的楼层
                echo "找到以下最接近的楼层："
                local count=0
                for item in "${floor_diffs[@]}"; do
                    IFS=':' read -r diff floor <<< "$item"
                    count=$((count + 1))
                    echo "$count. $floor 楼 (相差: $diff)"
                    closest_floors+=("$floor")
                    [ "$count" -eq 3 ] && break
                done
                
                echo -n "请选择楼层 (1-$count)："
                read -r closest_index
                
                if [ -z "$closest_index" ]; then
                    echo "已取消导入操作"
                    press_any_key
                    return
                elif [[ ! "$closest_index" =~ ^[0-9]+$ ]] || [ "$closest_index" -lt 1 ] || [ "$closest_index" -gt "$count" ]; then
                    echo "无效的序号，请重新输入。"
                else
                    target_floor="${closest_floors[$((closest_index-1))]}"
                    break
                fi
            fi
        else
            echo "无效选择，请重新输入 (1 或 2):"
        fi
    done
    
    # 找到对应楼层的文件
    local file_to_import=""
    for file in "${floor_files[@]}"; do
        local basename=$(basename "$file")
        if [[ "$basename" =~ ^${target_floor}楼 ]]; then
            file_to_import="$file"
            break
        fi
    done
    
    if [ -z "$file_to_import" ]; then
        echo "未找到对应楼层的文件，导入失败。"
        press_any_key
        return
    fi
    
    # 选择导入方式
    local import_type=""
    while true; do
        echo ""
        echo "请选择导入方式:"
        echo "1. 覆盖原始聊天记录"
        echo "2. 新建聊天记录"
        echo -n "请选择 (1-2, 直接回车取消)："
        read -r import_type
        
        if [ -z "$import_type" ]; then
            echo "已取消导入操作"
            press_any_key
            return
        elif [ "$import_type" = "1" ] || [ "$import_type" = "2" ]; then
            break
        else
            echo "无效选择，请重新输入 (1 或 2)"
        fi
    done
    
    # 确定目标文件名和路径
    local target_filename=""
    if [ "$import_type" = "1" ]; then
        # 覆盖原始聊天记录
        target_filename="${SOURCE_DIR}/${char_name}/${chat_name}.jsonl"
    else
        # 新建聊天记录
        target_filename="${SOURCE_DIR}/${char_name}/${chat_name} imported.jsonl"
    fi
    
    # 确保目标目录存在
    mkdir -p "$(dirname "$target_filename")"
    
    # 显示确认信息
    echo ""
    echo "即将导入文件:"
    echo "源文件: $file_to_import"
    echo "目标文件: $target_filename"
    echo -n "确认导入? (y/n)"
    read -r confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消导入操作"
        press_any_key
        return
    fi
    
    # 执行导入
    echo "正在导入文件..."
    
    # 检查文件类型并解压或复制
    if [[ "$file_to_import" == *.xz ]]; then
        xz -dc "$file_to_import" > "$target_filename"
    else
        cp "$file_to_import" "$target_filename"
    fi
    
    if [ $? -eq 0 ]; then
        echo "导入成功！"
    else
        echo "导入失败，请检查文件权限和磁盘空间。"
    fi
    
    press_any_key
}

# 压缩全部聊天存档功能
compress_all_chats() {
    clear
    echo "====== 压缩全部聊天存档 ======"
    
    # 检查是否安装了xz
    if ! command -v xz &> /dev/null; then
        echo "未安装xz工具，正在尝试安装..."
        install_xz
        
        # 再次检查是否安装成功
        if ! command -v xz &> /dev/null; then
            echo "安装xz工具失败，无法继续压缩操作。"
            press_any_key
            return 1
        fi
    fi
    
    echo "正在扫描需要压缩的存档文件..."
    
    # 递归查找所有的jsonl文件
    local jsonl_files=()
    mapfile -t jsonl_files < <(find "$SAVE_BASE_DIR" -type f -name "*.jsonl")
    
    local total_files=${#jsonl_files[@]}
    local compressed_files=0
    local failed_files=0
    
    if [ $total_files -eq 0 ]; then
        echo "未找到需要压缩的聊天存档文件。"
        press_any_key
        return
    fi
    
    echo "找到 $total_files 个存档文件，开始压缩..."
    echo "请稍候，这可能需要一些时间..."
    
    for file in "${jsonl_files[@]}"; do
        # 创建压缩文件名
        local xz_file="${file%.jsonl}.xz"
        
        # 如果已存在同名的xz文件，直接删除原始jsonl文件
        if [ -f "$xz_file" ]; then
            rm -f "$file"
            compressed_files=$((compressed_files + 1))
            continue
        fi
        
        # 压缩文件
        if xz -c "$file" > "$xz_file"; then
            # 压缩成功，删除原始文件
            rm -f "$file"
            compressed_files=$((compressed_files + 1))
        else
            failed_files=$((failed_files + 1))
        fi
    done
    
    echo ""
    echo "压缩完成！"
    echo "总共处理: $total_files 个文件"
    echo "成功压缩: $compressed_files 个文件"
    
    if [ $failed_files -gt 0 ]; then
        echo "压缩失败: $failed_files 个文件"
    fi
    
    press_any_key
}

# 主菜单界面
main_menu() {
    while true; do
        clear
        echo -e "\033[32m按Ctrl+C退出程序\033[0m"
        echo "作者：柳拂城"
        echo "版本：1.3.3"
        echo "首次使用请先输入2进入设置（记得看GitHub上的Readme）"
        echo "第一次写脚本，如遇bug请在GitHub上反馈( *ˊᵕˋ)✩︎‧₊"
        echo "GitHub链接：https://github.com/Liu-fucheng/Jsonl_monitor"
        echo ""
        echo "===== JSONL自动存档工具 ====="
        echo "1. 启动"
        echo "2. 设置"
        echo "3. 更新"
        echo "4. 清除冗余存档"
        echo "5. 存档全部聊天记录"
        echo "6. 压缩全部聊天存档"
        echo "7. 导入聊天记录进酒馆"
        echo "8. 退出"

        echo -n "选择: "
        choice=$(get_single_key)
        echo "$choice"
        
        case "$choice" in
            1)
                start_monitoring
                # 确保恢复终端设置
                stty sane
                ;;
            2)
                settings_menu
                ;;
            3)
                update_script
                ;;
            4)
                cleanup_menu
                ;;
            5)
                archive_all_chats
                ;;
            6)
                compress_all_chats
                ;;
            7)
                import_chat_records
                ;;
            8)
                echo "退出程序"
                exit 0
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
    done
}

update_script() {
    clear
    echo "正在检查更新..."
    
    # 临时目录用于下载
    TEMP_DIR="$SCRIPT_DIR/temp_update"
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    # 检查是否安装必要的命令
    if ! command -v curl &> /dev/null; then
        echo "未安装 curl，正在尝试安装..."
        pkg install curl -y
        if [ $? -ne 0 ]; then
            echo "安装 curl 失败，请手动安装后重试。"
            press_any_key
            cd "$SCRIPT_DIR"
            rm -rf "$TEMP_DIR"
            return 1
        fi
    fi
    
    # 检查是否安装 git
    if ! command -v git &> /dev/null; then
        echo "未安装 git，正在尝试安装..."
        pkg install git -y
        if [ $? -ne 0 ]; then
            echo "安装 git 失败，请手动安装后重试。"
            press_any_key
            cd "$SCRIPT_DIR"
            rm -rf "$TEMP_DIR"
            return 1
        fi
    fi
    
    # 检测IP地理位置，决定是否使用代理
    echo "检测IP地理位置，判断是否使用GitHub代理..."
    local country_code
    country_code=$(curl -s --connect-timeout 5 ipinfo.io/country)
    local download_url=""
    
    if [ -n "$country_code" ] && [[ "$country_code" =~ ^[A-Z]{2}$ ]]; then
        echo "检测到国家代码: $country_code"
        if [ "$country_code" = "CN" ]; then
            echo "检测到中国大陆IP，默认启用GitHub代理: $GH_FAST"
            read -rp "是否禁用GitHub代理进行下载？(y/N): " disable_proxy
            if [[ "$disable_proxy" =~ ^[Yy]$ ]]; then
                download_url="https://github.com/${GITHUB_REPO}.git"
                echo "已禁用GitHub代理，将直连GitHub下载。"
            else
                download_url="${GH_FAST}https://github.com/${GITHUB_REPO}.git"
                echo "将使用GitHub代理下载: $GH_FAST"
            fi
        else
            download_url="https://github.com/${GITHUB_REPO}.git"
            echo "非中国大陆IP，将直连GitHub下载。"
        fi
    else
        echo "无法检测IP地理位置或国家代码无效，将直连GitHub下载。"
        download_url="https://github.com/${GITHUB_REPO}.git"
    fi

    # 从GitHub下载最新代码
    echo "从 GitHub 下载最新代码..."
    if [ "$country_code" = "CN" ] && [[ ! "$disable_proxy" =~ ^[Yy]$ ]]; then
        # 中国用户且未禁用代理时，使用curl直接下载
        echo "正在使用curl直接下载jsonl.sh..."
        local raw_url="https://raw.githubusercontent.com/${GITHUB_REPO}/main/jsonl.sh"
        local proxy_url="${GH_FAST}${raw_url#https://}"
        curl -O "${proxy_url}"
        if [ $? -eq 0 ]; then
            echo "直接下载成功"
        else
            echo "直接下载失败，尝试使用git..."
            if [ -d ".git" ]; then
                git pull
            else
                git clone "$download_url" .
            fi
        fi
    else
        # 非中国用户或禁用代理时，使用git
        if [ -d ".git" ]; then
            # 如果已经是git仓库，更新
            git pull
        else
            # 否则克隆仓库
            git clone "$download_url" .
        fi
    fi
    
    if [ $? -eq 0 ]; then
        echo "下载成功，正在更新脚本..."
        
        # 确保脚本有执行权限
        chmod +x jsonl.sh
        
        # 复制到脚本目录
        cp -f jsonl.sh "$SCRIPT_DIR/"
        
        # 删除临时目录
        cd "$SCRIPT_DIR"
        rm -rf "$TEMP_DIR"
        
        echo "更新成功！当前为最新版本。"
        echo "请重新启动脚本以应用更新。"
        
        # 提示用户重启脚本
        read -p "现在重启脚本吗？(y/n): " restart
        if [ "$restart" = "y" ] || [ "$restart" = "Y" ]; then
            echo "重启脚本..."
            exec bash "$SCRIPT_DIR/jsonl.sh"
        fi
    else
        echo "更新失败，请检查网络连接或手动下载。"
        cd "$SCRIPT_DIR"
        rm -rf "$TEMP_DIR"
    fi
    
    press_any_key
}

# 启动监控
start_monitoring() {
    clear
    # 执行初始扫描（只记录信息，不处理变化）
    initial_scan
    
    echo "保存行数记录到日志文件... (共 ${#line_counts[@]} 条记录)"
    
    echo "开始监控JSONL文件变化..."
    echo -e "\033[32m按Ctrl+C退出程序\033[0m"
    
    # 设置trap捕获信号
    trap 'echo "退出程序..."; exit 0' SIGINT  # Ctrl+C
    
    # 循环监控
    while true; do
        # 执行智能扫描
        smart_scan
    done
}

# 清理函数 - 程序退出时执行
cleanup_on_exit() {
    save_line_counts
    save_rules
    # 确保恢复终端设置
    stty sane
    stty echo
    stty icanon
    # 只在正常退出时显示提示
    if [ "$1" != "SIGINT" ]; then
        echo "程序已退出"
    fi
}

# 修复规则格式
fix_rule_formats() {
    local need_save=0
    
    # 修复全局规则
    for i in "${!GLOBAL_RULES[@]}"; do
        local rule="${GLOBAL_RULES[$i]}"
        if [[ "$rule" != *":"* ]]; then
            # 如果规则不包含冒号，解析并重构
            read -r rule_type params <<< $(parse_rule "$rule")
            GLOBAL_RULES[$i]="${rule_type}:${params}"
            need_save=1
        fi
    done
    
    # 修复角色规则
    for char_name in "${!CHAR_RULES[@]}"; do
        local rule="${CHAR_RULES[$char_name]}"
        if [[ "$rule" != *":"* ]]; then
            # 如果规则不包含冒号，解析并重构
            read -r rule_type params <<< $(parse_rule "$rule")
            CHAR_RULES["$char_name"]="${rule_type}:${params}"
            need_save=1
        fi
    done
    
    # 修复聊天规则
    for chat_path in "${!CHAT_RULES[@]}"; do
        local rule="${CHAT_RULES[$chat_path]}"
        if [[ "$rule" != *":"* ]]; then
            # 如果规则不包含冒号，解析并重构
            read -r rule_type params <<< $(parse_rule "$rule")
            CHAT_RULES["$chat_path"]="${rule_type}:${params}"
            need_save=1
        fi
    done
    
    # 如果有修复，保存规则
    if [ $need_save -eq 1 ]; then
        save_rules
    fi
}

# 设置清理钩子 - SIGINT、SIGTERM和SIGHUP都执行完整的清理
trap cleanup_on_exit SIGTERM SIGINT SIGHUP EXIT

# 设置空的SIGINT处理器，覆盖前面可能的处理器
trap '' SIGINT

# 主入口
main() {
    # 设置信号处理
    trap 'cleanup_on_exit SIGINT; exit 0' SIGINT
    trap 'cleanup_on_exit; exit 0' SIGTERM SIGHUP EXIT|
    
    # 检查依赖
    check_dependencies
    
    # 加载配置
    load_config
    
    # 加载规则
    load_rules
    
    # 修复规则格式
    fix_rule_formats
    
    # 从日志文件加载之前的行数记录
    load_line_counts
    
    # 主菜单
    main_menu
}

# 执行主函数
main
