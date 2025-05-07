#!/bin/bash

#脚本信息
shellname="jsonl.sh"
VERSION="1.5.0"
GH_FAST="https://ghfast.top/"
GITHUB_REPO="Liu-fucheng/Jsonl_monitor"
GH_DOWNLOAD_URL_BASE="https://github.com/${GITHUB_REPO}/raw/main"

#路径
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SILLY_TAVERN_DIR="${SCRIPT_DIR}/SillyTavern"
USERNAME="default-user"
SOURCE_DIR="${SILLY_TAVERN_DIR}/data/${USERNAME}/chats"
SAVE_BASE_DIR="${SCRIPT_DIR}/saved-date/${USERNAME}/chats"
LOG_DIR="${SCRIPT_DIR}/saved-date"
LOG_FILE="${LOG_DIR}/line_counts.log"
CONFIG_FILE="${LOG_DIR}/config.conf"
RULES_FILE="${LOG_DIR}/rules.txt"

#默认配置
SAVE_INTERVAL=20
SAVE_MODE="interval"
ROLLBACK_MODE=1
SORT_METHOD="name"
SORT_ORDER="asc"
INITIAL_SCAN_ARCHIVE=0
SAVE_ARCHIVE_COUNT=10

INITIAL_SCAN=0
last_processed_file=""
SELECTED_CHAR_NAME=""
BROWSE_CHAT_COUNT=0
BROWSE_CHAT_KEYS=()
declare -a GLOBAL_RULES
declare -A CHAR_RULES
declare -A CHAT_RULES
declare -A line_counts
declare -A mod_times
declare -A line_reduced
declare -A file_md5s

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE_ON_RED="\e[97;41m"
RESET="\e[0m"

#检查新版本
check_for_updates() {
    local CURRENT_VERSION="$VERSION"
    local VERSION_CHECK_FILE="$LOG_DIR/version_check.txt"
    local CHECK_INTERVAL=$((1 * 24 * 60 * 60))
    
    if [ ! -f "$VERSION_CHECK_FILE" ]; then
        echo "last_check=0" > "$VERSION_CHECK_FILE"
        echo "latest_version=$CURRENT_VERSION" >> "$VERSION_CHECK_FILE"
        echo "has_notified=0" >> "$VERSION_CHECK_FILE"
    fi

    local last_check=$(grep "last_check=" "$VERSION_CHECK_FILE" | cut -d= -f2)
    local latest_version=$(grep "latest_version=" "$VERSION_CHECK_FILE" | cut -d= -f2)
    local has_notified=$(grep "has_notified=" "$VERSION_CHECK_FILE" | cut -d= -f2)

    local current_time=$(date +%s)
    
    if ! command -v curl &> /dev/null; then
        return
    fi

    if [ $((current_time - last_check)) -gt $CHECK_INTERVAL ]; then
        update_version_info "$VERSION_CHECK_FILE" "$CURRENT_VERSION" "$latest_version" "$has_notified"
    elif [ "$has_notified" -eq 0 ] && [ "$latest_version" != "$CURRENT_VERSION" ]; then
        display_update_notification "$latest_version" "$CURRENT_VERSION"
        sed -i "s/has_notified=0/has_notified=1/g" "$VERSION_CHECK_FILE" 2>/dev/null || \
        sed "s/has_notified=0/has_notified=1/g" "$VERSION_CHECK_FILE" > "$VERSION_CHECK_FILE.tmp" && \
        mv "$VERSION_CHECK_FILE.tmp" "$VERSION_CHECK_FILE"
    fi
}

# 更新版本信息
update_version_info() {
    local VERSION_CHECK_FILE="$1"
    local CURRENT_VERSION="$2"
    local previous_latest_version="$3"
    local has_notified="$4"
    
    local current_time=$(date +%s)

    (
        local TEMP_CHECK_DIR="$LOG_DIR/temp_version_check"
        mkdir -p "$TEMP_CHECK_DIR"
        cd "$TEMP_CHECK_DIR" || return
        
        local country_code
        country_code=$(curl -s --connect-timeout 5 ipinfo.io/country)
        local download_url="https://github.com/Liu-fucheng/Jsonl_monitor.git"
        
        if [ "$country_code" = "CN" ]; then
            download_url="https://ghproxy.com/https://github.com/Liu-fucheng/Jsonl_monitor.git"
        fi
        
        git clone --depth=1 "$download_url" . > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            local remote_version
            remote_version=$(grep -o "当前版本：[0-9.]*" ${shellname} | cut -d'：' -f2 2>/dev/null)
            
            if [ -z "$remote_version" ]; then
                remote_version=$(grep -o "版本：[0-9.]*" ${shellname} | cut -d'：' -f2 2>/dev/null)
            fi
            
            if [ -z "$remote_version" ]; then
                remote_version=$(grep -o "VERSION=\"[0-9.]*\"" ${shellname} | grep -o "[0-9.]*" 2>/dev/null)
            fi
            
            if [ -n "$remote_version" ]; then
                echo "last_check=$current_time" > "$VERSION_CHECK_FILE"
                echo "latest_version=$remote_version" >> "$VERSION_CHECK_FILE"
                
                if [ "$remote_version" != "$CURRENT_VERSION" ]; then
                    echo "has_notified=0" >> "$VERSION_CHECK_FILE"
                else
                    echo "has_notified=1" >> "$VERSION_CHECK_FILE"
                fi
            fi
        else
            echo "last_check=$current_time" > "$VERSION_CHECK_FILE"
            echo "latest_version=$previous_latest_version" >> "$VERSION_CHECK_FILE"
            echo "has_notified=$has_notified" >> "$VERSION_CHECK_FILE"
        fi
        
        cd "$LOG_DIR" || return
        rm -rf "$TEMP_CHECK_DIR"
    ) &
}

# 显示更新通知
display_update_notification() {
    local latest_version="$1"
    local current_version="$2"

    echo ""
    echo "============================================="
    echo "              新版本可用!"
    echo "============================================="
    echo "当前版本: $current_version"
    echo "最新版本: $latest_version"
    echo ""
    echo "您可以通过主菜单中的'更新'选项进行更新。"
    echo "============================================="
    echo ""
}


# 更新脚本
update_script() {
     clear
     echo "正在检查更新..."
 
     TEMP_DIR="$SCRIPT_DIR/temp_update"
     mkdir -p "$TEMP_DIR"
     cd "$TEMP_DIR"
 
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
 
     echo "从 GitHub 下载最新代码..."
     if [ "$country_code" = "CN" ] && [[ ! "$disable_proxy" =~ ^[Yy]$ ]]; then
         echo "正在使用curl直接下载${shellname}..."
         local raw_url="https://raw.githubusercontent.com/${GITHUB_REPO}/main/${shellname}"
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
         if [ -d ".git" ]; then
             git pull
         else
             git clone "$download_url" .
         fi
     fi
 
     if [ $? -eq 0 ]; then
         echo "下载成功，正在更新脚本..."
 
         chmod +x ${shellname}
 
         cp -f ${shellname} "$SCRIPT_DIR/"
 
         cd "$SCRIPT_DIR"
         rm -rf "$TEMP_DIR"
 
         echo "更新成功！当前为最新版本。"
         echo "请重新启动脚本以应用更新。"
 
         read -p "现在重启脚本吗？(y/n): " restart
         if [ "$restart" = "y" ] || [ "$restart" = "Y" ]; then
             echo "重启脚本..."
             exec bash "$SCRIPT_DIR/${shellname}"
         fi
     else
         echo "更新失败，请检查网络连接或手动下载。"
         cd "$SCRIPT_DIR"
         rm -rf "$TEMP_DIR"
     fi
 
     press_any_key
}

#检查依赖(md5)
check_dependencies() {
    local missing=0
    if ! command -v md5sum &> /dev/null && ! command -v md5 &> /dev/null; then
        echo "错误：缺少 MD5 校验工具（需要 md5sum 或 md5）" >&2
        missing=1
    fi

      # 如果缺少依赖，提示安装
      if [ "$missing" -ne 0 ]; then
          while true; do
              read -n 1 -p "是否自动安装依赖？[y/n]" choice
              echo
              if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
                  pkg update -y && pkg install -y coreutils
                  break
              elif [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
                  echo "请手动运行：pkg install coreutils" >&2
                  exit 1
              else
                  echo "无效输入，请输入 y 或 n"
              fi
          done
      fi
}

# 按任意键继续
press_any_key() {
    read -n 1 -s -r -p "按任意键继续..."
    echo
}

#排序方式选择
ask_sort_method(){
  echo "请选择排序方式:"
  echo "1. 按名称排序 (英文在前，中文在后; 按s切换升/降序)"
  echo "2. 按修改时间排序 (按s切换新旧顺序)"
  while true; do
    read -n 1 -p "请选择 [1/2]: " choice
    case "$choice" in
      1)
        SORT_METHOD="name"
        break
        ;;
      2)
        SORT_METHOD="time"
        break
        ;;
      s|S)
        if [ "$SORT_ORDER" = "asc" ]; then
          SORT_ORDER="desc"
          break
        else
          SORT_ORDER="asc"
          break
        fi
        ;;
      *)
        echo "无效选择"
        ;;
    esac
  done

  local method_desc="按名称排序"
  local order_desc="升序"
  
  if [ "$SORT_METHOD" = "time" ]; then
    method_desc="按修改时间排序"
  fi

  if [ "$SORT_ORDER" = "desc" ]; then
    order_desc="降序"
  fi
  echo
  echo "当前排序方式为: $method_desc ($order_desc)"
  echo "按 's' 可以切换升/降序"
  echo ""

  save_config
}

#退出提示
exit_prompt(){
  echo -e "${GREEN}按Ctrl+C退出程序${RESET}"
}

#保存配置
save_config() {
    echo "SAVE_INTERVAL=$SAVE_INTERVAL" > "$CONFIG_FILE"
    echo "SAVE_MODE=$SAVE_MODE" >> "$CONFIG_FILE"
    echo "ROLLBACK_MODE=$ROLLBACK_MODE" >> "$CONFIG_FILE"
    echo "SORT_METHOD=$SORT_METHOD" >> "$CONFIG_FILE"
    echo "SORT_ORDER=$SORT_ORDER" >> "$CONFIG_FILE"
    echo "USERNAME=$USERNAME" >> "$CONFIG_FILE"
    echo "INITIAL_SCAN_ARCHIVE=$INITIAL_SCAN_ARCHIVE" >> "$CONFIG_FILE"
    echo "SAVE_ARCHIVE_COUNT=$SAVE_ARCHIVE_COUNT" >> "$CONFIG_FILE"
}

#加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        SOURCE_DIR="${SILLY_TAVERN_DIR}/data/${USERNAME}/chats"
        SAVE_BASE_DIR="${SCRIPT_DIR}/saved-date/${USERNAME}/chats"
    else
        save_config
    fi
}

#初始化目录
initialize_directories(){
  if [ ! -d "$SILLY_TAVERN_DIR" ]; then
      echo -e "\033[31m错误：脚本放置层级错误，未找到SillyTavern目录！\033[0m"
      echo -e "\033[31m请确保脚本与SillyTavern目录处于同一层级，通常位于/root目录下\033[0m"
      exit 1
  fi

  if [ ! -d "$SOURCE_DIR" ]; then
      echo -e "\033[31m错误：聊天目录不存在\033[0m"
      read -n 1 -p "\033[31m请输入正确的用户名（回车确认）：\033[0m" USERNAME
      SOURCE_DIR="${SILLY_TAVERN_DIR}/data/${USERNAME}/chats"
      SAVE_BASE_DIR="${SCRIPT_DIR}/saved-date/${USERNAME}/chats"
      save_config
  fi

  mkdir -p "$SOURCE_DIR"
  mkdir -p "$SAVE_BASE_DIR"
  mkdir -p "$LOG_DIR"
}

#显示规则
display_rule(){
  local rule="$1"
  local index="$2"
  local mode="${3:-compact}"
  IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
  case "$rule_type" in
    "interval_above")
      IFS=',' read -r min_floor range interval <<< "$params"
      if [ "$mode" = "compact" ]; then
        echo -e "${min_floor}楼以上只保留最近${range}楼内${interval}的倍数"
      else
        echo -e "$index. ${min_floor}楼以上只保留最近${range}楼内${interval}的倍数"
      fi
      ;;
    "latest_above")
      if [ "$mode" = "compact" ]; then
        echo -e "${params}楼以上只保留最新楼层"
      else
        echo -e "$index. ${params}楼以上只保留最新楼层"
      fi
      ;;
    *)
      if [ "$mode" = "compact" ]; then
        echo -e "未知规则类型"
      else
        echo -e "$index. 未知规则类型"
      fi
      ;;
  esac
}

#解析规则
parse_rule(){
  local rule="$1"
  local rule_type=""
  local params=""
  
  if [[ "$rule" == interval_above:* ]]; then
    local rule_type="interval_above"
    local params="${rule#interval_above:}"
    echo "$rule_type|$params"
    return
  elif [[ "$rule" == latest_above:* ]]; then
    local rule_type="latest_above"
    local params="${rule#latest_above:}"
    echo "$rule_type|$params"
    return
  fi

  if [[ "$rule" == interval_above* ]] && [[ "$rule" != *":"* ]]; then
    local params="${rule#interval_above }"
    echo "interval_above|$params"
    return
  elif [[ "$rule" == latest_above* ]] && [[ "$rule" != *":"* ]]; then
    local params="${rule#latest_above }"
    echo "latest_above|$params"
    return
  fi
}

#编辑规则
edit_rule(){
  local rule_scope="$1"
  local target="$2"
  target="${target}"
  local rule_idx="${3:-0}"

  local rule=""

  if [ "$rule_scope" = "global" ]; then
    rule="${GLOBAL_RULES[$target]}"
  elif [ "$rule_scope" = "char" ]; then
    IFS=';' read -ra rules <<< "${CHAR_RULES[$target]}"
    rule="${rules[$rule_idx]}"
  elif [ "$rule_scope" = "chat" ]; then
    IFS=';' read -ra rules <<< "${CHAT_RULES[$target]}"
    rule="${rules[$rule_idx]}"
  fi

  if [ -z "$rule" ]; then
    echo "未找到规则或索引无效"
    press_any_key
    return
  fi

  if [[ "$rule" == interval_above:* ]]; then
    local params="${rule#interval_above:}"
    IFS=',' read -ra args <<< "$params"
    local min_floor="${args[0]}"
    local range="${args[1]}"
    local interval="${args[2]}"
    echo "当前规则: ${min_floor}楼以上只保留最近${range}楼内${interval}的倍数"
    read -p "请输入新的三个参数(用逗号或空格分隔): " params

    params=${params//，/,}
    params=${params// /,}

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

    local new_rule="interval_above:$min_floor,$range,$interval"

    if [ "$rule_scope" = "global" ]; then
      GLOBAL_RULES[$target]="$new_rule"
    elif [ "$rule_scope" = "char" ]; then
      CHAR_RULES["$target"]="$new_rule"
    elif [ "$rule_scope" = "chat" ]; then
      CHAT_RULES["$target"]="$new_rule"
    fi
  elif [[ "$rule" == latest_above:* ]]; then
    local params="${rule#latest_above:}"
    echo "当前规则: ${params}楼以上只保留最新楼层"
    read -p "请输入新的起始楼层: " params

    if [[ ! $params =~ ^[0-9]+$ ]]; then
      echo "楼层必须为数字"
      press_any_key
      return
    fi
    
    local new_rule="latest_above:$params"

    if [ "$rule_scope" = "global" ]; then
      GLOBAL_RULES[$target]="$new_rule"
    elif [ "$rule_scope" = "char" ]; then
      CHAR_RULES["$target"]="$new_rule"
    elif [ "$rule_scope" = "chat" ]; then
      CHAT_RULES["$target"]="$new_rule"
    fi
  fi

  save_rules
  echo "规则修改成功！"
  press_any_key
}

#添加规则
add_rule(){
  local rule_scope="$1"
  local target="$2"
  target="${target}"
  echo
  echo "规则模板:"
  echo "1. __楼以上只保留最近__楼内__的倍数"
  echo "2. __楼以上只保留最新楼层"
  while true; do
    read -n 1 -p "选择规则模板(1/2，回车取消): " choice
    echo
    if [ "$choice" = "1" ]; then
      while true; do
        read -p "请输入三个参数(用逗号或空格分隔): " params
        params=${params//，/,}
        params=${params// /,}
        IFS=',' read -ra parts <<< "$params"
        if [ -z "$params" ]; then
          echo "取消操作"
          press_any_key
          return
        fi
        if [ ${#parts[@]} -ne 3 ]; then
          echo "参数数量不正确，需要三个参数"
          continue
        fi
        local min_floor="${parts[0]}"
        local range="${parts[1]}"
        local interval="${parts[2]}"
        if [[ ! $min_floor =~ ^[0-9]+$ ]] || [[ ! $range =~ ^[0-9]+$ ]] || [[ ! $interval =~ ^[0-9]+$ ]]; then
          echo "参数必须为数字"
          continue
        fi
        break
      done
      local rule="interval_above:$min_floor,$range,$interval"
      if [ "$rule_scope" = "global" ]; then
          if [ -n "$GLOBAL_RULES" ]; then
            GLOBAL_RULES+=("$rule") 
          else
            GLOBAL_RULES="$rule"
          fi
      elif [ "$rule_scope" = "char" ]; then
          if [ -n "${CHAR_RULES["$target"]}" ]; then
            CHAR_RULES["$target"]="${CHAR_RULES["$target"]};$rule"
          else
            CHAR_RULES["$target"]="$rule"
          fi
      elif [ "$rule_scope" = "chat" ]; then
          if [ -n "${CHAT_RULES["$target"]}" ]; then
            CHAT_RULES["$target"]="${CHAT_RULES["$target"]};$rule"
          else
            CHAT_RULES["$target"]="$rule"
          fi
      fi
      save_rules
      echo "规则添加成功！"
      press_any_key
      return
    elif [ "$choice" = "2" ]; then
      if [ "$rule_scope" = "global" ] && [ -n "$GLOBAL_RULES" ]; then
        local new_rule="latest_above:$min_floor"
        local updated_rules=""
        local latest_index=-1
        local has_latest=0
        for i in "${!GLOBAL_RULES[@]}"; do
          if [[ "${GLOBAL_RULES[$i]}" == latest_above* ]]; then
            has_latest=1
            latest_index=$i
            break
          fi
        done
        if [ "$has_latest" -eq 1 ]; then
          echo -n "当前已存在"
          display_rule "${GLOBAL_RULES[$latest_index]}" 1 "compact"
          echo -n "是否修改？(y/n)"
          echo
          read -n 1 -p "选择: " choice
          echo
          if [ "$choice" = "n" ] || [ "$choice" = "N" ] || [ -z "$choice" ]; then
            return
          else
            read -p "请输入新的起始楼层: " min_floor
            if [[ ! $min_floor =~ ^[0-9]+$ ]]; then
              echo "楼层必须为数字"
              continue
            fi
            GLOBAL_RULES[$latest_index]="latest_above:$min_floor"
            save_rules
            echo "规则修改成功！"
            press_any_key
            return
          fi
          return
        fi
      elif [ "$rule_scope" = "char" ] && [ -n "${CHAR_RULES["$target"]}" ]; then
        local new_rule="latest_above:$min_floor"
        local updated_rules=""
        IFS=';' read -ra char_rule_array <<< "${CHAR_RULES["$target"]}"
        for rule in "${char_rule_array[@]}"; do
          if [[ "$rule" != latest_above* ]]; then
            if [ -n "$updated_rules" ]; then
              updated_rules="$updated_rules;$rule"
            else
              updated_rules="$rule"
            fi
          fi
        done
        for rule in "${char_rule_array[@]}"; do
          if [[ "$rule" == latest_above* ]]; then
            echo -n "当前已存在"
            display_rule "$rule" 1 "compact"
            echo -n "是否修改？(y/n)"
            read -n 1 -p "选择: " choice
            if [ "$choice" = "n" ] || [ "$choice" = "N" ] || [ -z "$choice" ]; then
              return
            else
              read -p "请输入新的起始楼层: " min_floor
              if [[ ! $min_floor =~ ^[0-9]+$ ]]; then
                echo "楼层必须为数字"
                continue
              fi
              new_rule="latest_above:$min_floor"
              CHAR_RULES["$target"]="$new_rule;$updated_rules"
              save_rules
              echo "规则修改成功！"
              press_any_key
              return
            fi
            return
          fi
        done
      elif [ "$rule_scope" = "chat" ] && [ -n "${CHAT_RULES["$target"]}" ]; then
        local new_rule="latest_above:$min_floor"
        local updated_rules=""
        IFS=';' read -ra chat_rule_array <<< "${CHAT_RULES["$target"]}"
        for rule in "${chat_rule_array[@]}"; do
          if [[ "$rule" != latest_above* ]]; then
            if [ -n "$updated_rules" ]; then
              updated_rules="$updated_rules;$rule"
            else
              updated_rules="$rule"
            fi
          fi
        done
        for rule in "${chat_rule_array[@]}"; do
          if [[ "$rule" == latest_above* ]]; then
            echo -n "当前已存在"
            display_rule "$rule" 1 "compact"
            echo -n "是否修改？(y/n)"
            read -n 1 -p "选择: " choice
            if [ "$choice" = "n" ] || [ "$choice" = "N" ] || [ -z "$choice" ]; then
              return
            else
              read -p "请输入新的起始楼层: " min_floor
              if [[ ! $min_floor =~ ^[0-9]+$ ]]; then
                echo "楼层必须为数字"
                continue
              fi
              new_rule="latest_above:$min_floor"
              CHAT_RULES["$target"]="$new_rule;$updated_rules"
              save_rules
              echo "规则修改成功！"
              press_any_key
              return
            fi
            return
          fi
        done
      fi
      while true; do
        read -p "请输入起始楼层: " min_floor
        if [ -z "$min_floor" ]; then
          echo "取消操作"
          return
        fi
        if [[ ! $min_floor =~ ^[0-9]+$ ]]; then
          echo "楼层必须为数字"
          continue
        fi
        new_rule="latest_above:$min_floor"
        if [ "$rule_scope" = "global" ]; then
          GLOBAL_RULES="$new_rule;$updated_rules"
        elif [ "$rule_scope" = "char" ]; then
          CHAR_RULES["$target"]="$new_rule;$updated_rules"
        elif [ "$rule_scope" = "chat" ]; then
          CHAT_RULES["$target"]="$new_rule;$updated_rules"
        fi
        save_rules
        echo "规则添加成功！"
        press_any_key
        return
      done
    elif [ -z "$choice" ]; then
      return
    else
      echo "无效输入，请输入 1 或 2"
    fi
  done

  return
}

#保存规则
save_rules(){
  sort_rules

  local temp_rules_file="${RULES_FILE}.tmp"
  > "$temp_rules_file"

  if [ ${#GLOBAL_RULES[@]} -gt 0 ]; then
      for rule in "${GLOBAL_RULES[@]}"; do
        IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
        rule="${rule_type}:${params}"
        echo "global||$rule" >> "$temp_rules_file"
      done
  fi

  for char_name in "${!CHAR_RULES[@]}"; do
    local rule="${CHAR_RULES[$char_name]}"
    IFS=';' read -ra char_rule_array <<< "$rule"
    for rule in "${char_rule_array[@]}"; do
      IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
      rule="${rule_type}:${params}"
      echo "char|$char_name|$rule" >> "$temp_rules_file"
    done
  done

  for chat_path in "${!CHAT_RULES[@]}"; do
    local rule="${CHAT_RULES[$chat_path]}"
    IFS=';' read -ra chat_rule_array <<< "$rule"
    for rule in "${chat_rule_array[@]}"; do
      IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
      rule="${rule_type}:${params}"
      echo "chat|$chat_path|$rule" >> "$temp_rules_file"
    done
  done

  mv "$temp_rules_file" "$RULES_FILE"
}

#加载规则
load_rules(){
  GLOBAL_RULES=()
  CHAR_RULES=()
  CHAT_RULES=()

  if [ -f "$RULES_FILE" ] && [ -s "$RULES_FILE" ]; then
      while IFS='|' read -r rule_scope target rule; do
          if [ "$rule_scope" = "global" ]; then
              GLOBAL_RULES+=("$rule")
          elif [ "$rule_scope" = "char" ]; then
              if [ -n "${CHAR_RULES[$target]}" ]; then
                  CHAR_RULES["$target"]="${CHAR_RULES[$target]};$rule"
              else
                  CHAR_RULES["$target"]="$rule"
              fi
          elif [ "$rule_scope" = "chat" ]; then
              # 聊天规则
              if [ -n "${CHAT_RULES[$target]}" ]; then
                  CHAT_RULES["$target"]="${CHAT_RULES[$target]};$rule"
              else
                  CHAT_RULES["$target"]="$rule"
              fi
          fi
      done < "$RULES_FILE"
  fi
}

#清理函数
cleanup_on_exit(){
  local static_var_name="__cleanup_done"
  if [ -n "${!static_var_name}" ]; then
    return
  fi
  eval $static_var_name=1

  save_line_counts
  save_rules
  
  if [ -t 0 ]; then
    stty sane 2>/dev/null
    stty echo 2>/dev/null
    stty icanon 2>/dev/null
  fi

  echo
  echo "程序已退出"

  local exit_code=${1:-0}
  exit $exit_code
}

# 处理范围选择，转换为选择列表
process_range_selection() {
    local input="$1"
    local max_items="$2"
    local selected=()
    
    input=${input//，/,}
    input=${input// /,}
    
    if [ "$input" = "全选" ]; then
        for ((i=1; i<=max_items; i++)); do
            selected+=($i)
        done
        echo "${selected[@]}"
        return
    fi
    
    IFS=',' read -ra parts <<< "$input"
    
    for part in "${parts[@]}"; do
        if [[ $part =~ ^[0-9]+-[0-9]+$ ]]; then
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
            if [ "$part" -le "$max_items" ] && [ "$part" -gt 0 ]; then
                selected+=($part)
            fi
        fi
    done
    
    echo $(printf "%s\n" "${selected[@]}" | sort -nu)
}

# 保存行数记录到日志文件
save_line_counts() {
    > "$LOG_FILE"
    for file in "${!line_counts[@]}"; do
        reduced=${line_reduced[$file]:-0}
        echo "${file#$SOURCE_DIR/}|${line_counts[$file]}|$reduced" >> "$LOG_FILE"
    done
}

#获取xz文件名
get_xz_unique_filename(){
    local base_name="$1"
    local content="$2"
    local special="${3:-0}"
    local temp_new_xz=$(mktemp)
    printf '%s' "$content" | xz -c > "$temp_new_xz"
    local base_file="${base_name}.xz"
    if [ -f "$base_file" ]; then
      if cmp -s "$temp_new_xz" "$base_file"; then
        rm -f "$temp_new_xz"
        return 1
      fi
    fi
    local output_file="$base_file"
    if [[ "$base_name" == *"_old"* ]] || [ $special -eq 1 ]; then
      local counter=1
      while [ -f "$output_file" ]; do
          output_file="${base_name}(${counter}).xz"
          if [ -f "$output_file" ]; then
              if cmp "$temp_new_xz" "$output_file"; then
                  rm -f "$temp_new_xz"
                  return 1
              fi
          fi
          counter=$((counter + 1))
      done
    fi
    rm -f "$temp_new_xz"
    echo "$output_file"
}

#排序规则
sort_rules(){
  local latest_rule=""
  local interval_rules=()
  local sorted_global_rules=""
  
  if [ -n "$GLOBAL_RULES" ]; then
    IFS=';' read -ra all_rules <<< "$GLOBAL_RULES"
    for rule in "${all_rules[@]}"; do
      IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
      if [ "$rule_type" = "latest_above" ]; then
        latest_rule="$rule"
      elif [ "$rule_type" = "interval_above" ]; then
        IFS=',' read -ra args <<< "$params"
        local min_floor="${args[0]}"
        interval_rules+=("$min_floor:$rule")
      fi
    done

    IFS=$'\n' sorted_interval_rules=($(sort -nr <<<"${interval_rules[*]}"))
    unset IFS

    if [ -n "$latest_rule" ]; then
      sorted_global_rules="$latest_rule"
    fi
    
    for item in "${sorted_interval_rules[@]}"; do
      local rule="${item#*:}"
      if [ -n "$sorted_global_rules" ]; then
        sorted_global_rules="$sorted_global_rules;$rule"
      else
        sorted_global_rules="$rule"
      fi
    done
    
    GLOBAL_RULES="$sorted_global_rules"
  fi
  
  local char_names=("${!CHAR_RULES[@]}")
  for char_name in "${char_names[@]}"; do
    local latest_rule=""
    local interval_rules=()
    local sorted_char_rules=""
    
    IFS=';' read -ra all_rules <<< "${CHAR_RULES[$char_name]}"
    for rule in "${all_rules[@]}"; do
      IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
      if [ "$rule_type" = "latest_above" ]; then
        latest_rule="$rule"
      elif [ "$rule_type" = "interval_above" ]; then
        IFS=',' read -ra args <<< "$params"
        local min_floor="${args[0]}"
        interval_rules+=("$min_floor:$rule")
      fi
    done
    
    IFS=$'\n' sorted_interval_rules=($(sort -nr <<<"${interval_rules[*]}"))
    unset IFS
    
    if [ -n "$latest_rule" ]; then
      sorted_char_rules="$latest_rule"
    fi
    
    for item in "${sorted_interval_rules[@]}"; do
      local rule="${item#*:}"
      if [ -n "$sorted_char_rules" ]; then
        sorted_char_rules="$sorted_char_rules;$rule"
      else
        sorted_char_rules="$rule"
      fi
    done
    
    CHAR_RULES["$char_name"]="$sorted_char_rules"
  done
  
  local chat_keys=("${!CHAT_RULES[@]}")
  for chat_key in "${chat_keys[@]}"; do
    local latest_rule=""
    local interval_rules=()
    local sorted_chat_rules=""
    
    IFS=';' read -ra all_rules <<< "${CHAT_RULES[$chat_key]}"
    for rule in "${all_rules[@]}"; do
      IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
      if [ "$rule_type" = "latest_above" ]; then
        latest_rule="$rule"
      elif [ "$rule_type" = "interval_above" ]; then
        IFS=',' read -ra args <<< "$params"
        local min_floor="${args[0]}"
        interval_rules+=("$min_floor:$rule")
      fi
    done
    
    IFS=$'\n' sorted_interval_rules=($(sort -nr <<<"${interval_rules[*]}"))
    unset IFS
    
    if [ -n "$latest_rule" ]; then
      sorted_chat_rules="$latest_rule"
    fi
    
    for item in "${sorted_interval_rules[@]}"; do
      local rule="${item#*:}"
      if [ -n "$sorted_chat_rules" ]; then
        sorted_chat_rules="$sorted_chat_rules;$rule"
      else
        sorted_chat_rules="$rule"
      fi
    done
    
    CHAT_RULES["$chat_key"]="$sorted_chat_rules"
  done
}

#应用排序规则
apply_sorted_rules(){
  local floor="$1"
  local rule="$2"
  local latest_floor="${3:-0}"
  
  if [ -z "$rule" ]; then
    echo 2
    return
  fi

  local all_rules=()
  IFS=';' read -ra all_rules <<< "$rule"

  local latest_rules=()
  local interval_rules=()
  local rule_min_floors=()

  if [[ "$rule" == *";"* ]]; then
    IFS=';' read -ra all_rules <<< "$rule"
  else
    all_rules=("$rule")
  fi

  for rule in "${all_rules[@]}"; do
    IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
    local min_floor=0
    if [ "$rule_type" = "latest_above" ]; then
      min_floor="$params"
      if [ "$floor" -gt "$min_floor" ]; then
        echo 0
        return
      fi
    elif [ "$rule_type" = "interval_above" ]; then
      IFS=',' read -ra args <<< "$params"
      min_floor="${args[0]}"
      interval_rules+=("$min_floor:$rule")
    fi
  done

  IFS=$'\n' interval_rules=($(sort -nr <<<"${interval_rules[*]}"))
  unset IFS
  for item in "${interval_rules[@]}"; do
    local rule="${item#*:}"
    IFS='|' read -r rule_type params <<< $(parse_rule "$rule")
    if [ "$rule_type" = "interval_above" ]; then
      IFS=',' read -ra args <<< "$params"
      local min_floor="${args[0]}"
      local range="${args[1]}"
      local interval="${args[2]}"
      if [ "$floor" -ge "$min_floor" ]; then
        if [ "$((latest_floor - floor))" -le "$range" ]; then
          if [ $(( (floor - 1) % interval )) -eq 0 ]; then
            echo 2
            return
          fi
        fi
        echo 1
        return
      fi
    fi
  done
  echo 3
  return
}

#保存楼层
should_save_floor(){
  local floor="$1"
  local latest_floor="$2"
  local chat_dir="$3"

  local rel_path="${chat_dir#$SAVE_BASE_DIR/}"
  local char_name=$(echo "$rel_path" | cut -d'/' -f1)
  local chat_id=$(echo "$rel_path" | cut -d'/' -f2)
  local chat_key="$char_name|$chat_id"

  if [ "$floor" -eq "$latest_floor" ]; then
    echo 1
    return
  fi

  if [ -n "${CHAT_RULES[$chat_key]}" ]; then
    local result=$(apply_sorted_rules "$floor" "${CHAT_RULES[$chat_key]}" "$latest_floor")
    if [ "$result" -eq 0 ]; then
      echo 0
      return
    elif [ "$result" -eq 2 ]; then
      echo 2
      return
    fi
  fi
  
  if [ -n "${CHAR_RULES[${char_name}]}" ]; then
    local result=$(apply_sorted_rules "$floor" "${CHAR_RULES[$char_name]}" "$latest_floor")
    if [ "$result" -eq 0 ]; then
      echo 0
      return
    elif [ "$result" -eq 2 ]; then
      echo 2
      return
    fi
  fi
  
  if [ -n "$GLOBAL_RULES" ]; then
    local result=$(apply_sorted_rules "$floor" "$GLOBAL_RULES" "$latest_floor")
    if [ "$result" -eq 0 ]; then
      echo 0
      return
    elif [ "$result" -eq 2 ]; then
      echo 2
      return
    fi
  fi
  
  if [ "$SAVE_MODE" = "latest" ]; then
    echo 0
    return
  else
    if [ "$floor" -eq 1 ]; then
      echo 0
      return
    elif [ $(( (floor - 1) % SAVE_INTERVAL )) -eq 0 ]; then
      echo 1
      return
    else
      echo 0
      return
    fi
  fi
}

#导入存档到酒馆
import_archive_to_tavern(){ 
  local selected_dir="$1"
  local import_dir="$SOURCE_DIR/$(dirname "${selected_dir#$SAVE_BASE_DIR/}")"
  local latest_floor="${2:-0}"
  local latest_file=""
  local latest_mtime=0
  mkdir -p "$import_dir"

  local find_old_files=0
  local floor_files=()
  while true; do
    read -p "查找是否包括_old文件？(y/n)" choice
    echo
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
      mapfile -t floor_files < <(find "$selected_dir" -type f \( -name "*楼*.jsonl" -o -name "*楼*.xz" \))  
      mapfile -t old_files < <(find "$selected_dir" -type f \( -name "*楼*_old*.jsonl" -o -name "*楼*_old*.xz" \))  
      mapfile -t new_files < <(find "$selected_dir" -type f \( -name "*楼*.jsonl" -o -name "*楼*.xz" \) -not -name "*_old*")
      find_old_files=1
      break
    elif [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
      mapfile -t floor_files < <(find "$selected_dir" -type f \( -name "*楼*.jsonl" -o -name "*楼*.xz" \) -not -name "*_old*")      break
      break
    else
      echo "无效输入，请输入 y 或 n"
    fi
  done

  if [ ${#floor_files[@]} -eq 0 ]; then
    echo "存档文件夹为空，无法导入存档到酒馆"
    press_any_key
    return
  fi

  local floor_numbers=()
  for file in "${floor_files[@]}"; do
      local basename="${file##*/}"
      local floor_num=$(echo "$basename" | grep -oE '^[0-9]+' | head -1)
      if [ -n "$floor_num" ]; then
          floor_numbers+=("$floor_num")
      fi
  done
  IFS=$'\n' floor_numbers=($(sort -n <<<"${floor_numbers[*]}"))
  unset IFS

  local archive_floor=0
  if [ "$latest_floor" -eq 0 ]; then
    for archive_file in "$selected_dir"/*楼*.jsonl "$selected_dir"/*楼*.xz; do
        [ -f "$archive_file" ] || continue

      if [[ "$archive_file" == *"_old"* ]]; then
          continue
      fi
      local archive_floor=$(echo "$archive_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
      local mtime=$(stat -c %Y "$archive_file" 2>/dev/null || stat -f %m "$archive_file" 2>/dev/null)
      if [ "$mtime" -gt "$latest_mtime" ]; then
          latest_mtime=$mtime
          latest_floor=$archive_floor
      fi
    done
  fi

  local min_floor=${floor_numbers[0]}
  local max_floor=${floor_numbers[-1]}
  echo "存档文件夹共有${#floor_files[@]}个文件"
  echo "1. 导入最新楼层（${latest_floor}楼）"
  if [ "$find_old_files" -eq 1 ]; then
    local old_floor_exists=0
    for old_file in "${old_files[@]}"; do
      local old_floor=$(echo "$old_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
      if [ "$old_floor" = "$max_floor" ]; then
        old_floor_exists=1
        break
      fi
    done
    if [ "$old_floor_exists" -eq 1 ]; then
      local new_floor_numbers=()
      for new_file in "${new_files[@]}"; do
          local basename=$(basename "$new_file")
          local floor_num=$(echo "$basename" | grep -oE '^[0-9]+' | head -1)
          if [ -n "$floor_num" ]; then
              new_floor_numbers+=("$floor_num")
          fi
      done
      IFS=$'\n' new_floor_numbers=($(sort -n <<<"${new_floor_numbers[*]}"))
      unset IFS
      echo "2. 导入最高楼层（回退前的old存档${max_floor}楼/新存档${new_floor_numbers[-1]}楼）"
      echo "3. 导入指定楼层（新存档楼层范围：${min_floor}楼-${max_floor}楼，old存档楼层范围：${new_floor_numbers[0]}楼-${new_floor_numbers[-1]}楼）"
    else
      echo "2. 导入最高楼层（${max_floor}楼）"
      echo "3. 导入指定楼层（楼层范围：${min_floor}楼-${max_floor}楼）"
    fi
  else
    echo "2. 导入最高楼层（${max_floor}楼）"
    echo "3. 导入指定楼层（楼层范围：${min_floor}楼-${max_floor}楼）"
  fi
  
  while true; do
    read -n 1 -p "导入哪种楼层（回车取消）？" choice
    echo
    if [[ "$choice" -eq 3 ]]; then
      read -p "要导入的楼层数（回车确认，直接回车取消）：" target_floor
      local floor_exists=0
      for floor in "${floor_numbers[@]}"; do
          if [ "$floor" = "$target_floor" ]; then
              floor_exists=1
              break
          fi
      done
      if [ "$floor_exists" -eq 1 ]; then
        local file_to_import=""
        for file in "${floor_files[@]}"; do
          local basename="${file##*/}"
          if [[ "$basename" =~ ^${target_floor}楼 ]]; then
            file_to_import="$file"
            break
          fi
        done
      else
        echo "输入的楼层不存在，正在查找最接近的楼层..."
        local closest_floors=()
        local floor_diffs=()
        for floor in "${floor_numbers[@]}"; do
          local diff=$((floor > target_floor ? floor - target_floor : target_floor - floor))
          floor_diffs+=("$diff:$floor")
        done
        IFS=$'\n' floor_diffs=($(sort -n <<<"${floor_diffs[*]}"))
        unset IFS
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
          echo "无效的序号，请重新输入"
        else
          target_floor="${closest_floors[$((closest_index-1))]}"
          break
        fi
      fi
      break
    elif [[ "$choice" -eq 2 ]]; then
      if [ "$old_floor_exists" -eq 1 ]; then
        echo "1.导入回退前的old存档（${max_floor}楼）"
        echo "2.导入新存档（${new_floor_numbers[-1]}楼）"
        while true; do
          read -n 1 -p "请选择：" choice
          echo
          if [[ "$choice" -eq 1 ]]; then
            target_floor="$max_floor"
            break
          elif [[ "$choice" -eq 2 ]]; then
            target_floor="${new_floor_numbers[-1]}"
            break
          else
            echo "无效选择，请重新输入"
          fi
        done
      else
        target_floor="$max_floor"
      fi
      break
    elif [[ "$choice" -eq 1 ]]; then
      target_floor="$latest_floor"
      break
    elif [ -z "$choice" ]; then
      echo "已取消导入操作"
      press_any_key
      return
    else
      echo "无效选择，请重新输入"
    fi
  done

  if [ "$find_old_files" -eq 1 ]; then
    mapfile -t import_files < <(find "$selected_dir" -type f -name "${target_floor}楼*")
  else
    mapfile -t import_files < <(find "$selected_dir" -type f \(-name "${target_floor}楼*"\) -not -name "*_old*")
  fi
  local file_times=()
  local closest_files=()
  for file in "${import_files[@]}"; do
    local mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
    file_times+=("$mtime:$file")
  done
  IFS=$'\n' file_times=($(sort -n <<<"${file_times[*]}"))
  unset IFS
  if [ ${#file_times[@]} -eq 1 ]; then
    IFS=':' read -r _ file_to_import <<< "${file_times[0]}"
  else
    echo "找到以下文件（按修改时间从新到旧排序）："
    local count=0
    for item in "${file_times[@]}"; do
      IFS=':' read -r mtime file <<< "$item"
    count=$((count + 1))
    echo "$count. ${file##*/} (修改时间: $mtime)"
      closest_files+=("$file")
    done
    while true; do
      read -p "请选择文件 (1-$count)（回车确认，直接回车取消）：" choice
      echo
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
        file_to_import="${closest_files[$((choice-1))]}"
        break
      elif [ -z "$choice" ]; then
        echo "已取消导入操作"
        press_any_key
        return
      else
        echo "无效选择，请重新输入"
      fi
    done
  fi


  local import_type=""
  local target_filename=""
  echo "请选择导入方式:"
  echo "1. 覆盖原始聊天记录"
  echo "2. 新建聊天记录"
  while true; do
    read -n 1 -p "请选择 (1-2): " import_type
    echo
    if [[ "$import_type" -eq 1 ]]; then
      target_filename="${import_dir}.jsonl"
      break
    elif [[ "$import_type" -eq 2 ]]; then
      target_filename="${import_dir} imported.jsonl"
      break
    else
      echo "无效选择，请重新输入"
    fi
  done
  if [[ "$file_to_import" == *.xz ]]; then
    xz -cd "$file_to_import" > "$target_filename"
    echo "已将${file_to_import##*/}的内容导入到酒馆，覆盖现有文件"
  else
    cat "$file_to_import" > "$target_filename"
    echo "已将${file_to_import##*/}的内容导入到酒馆，创建新文件：${target_filename##*/}"
  fi
  press_any_key
}

#比较酒馆聊天记录与存档
compare_log_with_archives(){
  local file="$1"
  local log_floor="$2"

  local dir_name=$(dirname "${file#$SOURCE_DIR/}")
  local file_name=$(basename "${file#$SOURCE_DIR/}" .jsonl)

  local target_dir="$SAVE_BASE_DIR/$dir_name/$file_name"
  mkdir -p "$target_dir"
  
  local latest_floor=0
  local latest_file=""
  local latest_mtime=0
  local max_floor=0
  local max_file=""

  for archive_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
      [ -f "$archive_file" ] || continue

      if [[ "$archive_file" == *"_old"* ]]; then
          continue
      fi
      local archive_floor=$(echo "$archive_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
      local mtime=$(stat -c %Y "$archive_file" 2>/dev/null || stat -f %m "$archive_file" 2>/dev/null)
      if [ "$mtime" -gt "$latest_mtime" ]; then
          latest_mtime=$mtime
          latest_file="$archive_file"
          latest_floor=$archive_floor
      fi
  done

  if [ "$latest_floor" -eq 0 ] && [ "$INITIAL_SCAN_ARCHIVE" -eq 1 ]; then
      return
  fi

  if [ "$latest_floor" -ne "$log_floor" ]; then
    echo "检测到楼层不匹配: ${file#$SOURCE_DIR/}"
    echo "  - 酒馆聊天记录楼层: $log_floor"
    echo "  - 存档修改日期最新楼层: $latest_floor"

    if [ "$log_floor" -gt "$latest_floor" ]; then
      echo "酒馆聊天记录楼层高于存档修改日期最新楼层，执行普通新生成"
      local content=$(cat "$file")
      local base_save_name="${target_dir}/${log_floor}楼"
      local save_file=$(get_xz_unique_filename "$base_save_name" "$content")
      printf '%s' "$content" | xz -c > "$save_file"
      echo "已保存酒馆聊天记录文件: ${save_file##*/}"
      local result=$(should_save_floor "$latest_floor" "$log_floor" "$target_dir")
      if [ -n "$result" ] && [ "$result" -eq 0 ]; then
          for old_file in "$target_dir/${latest_floor}楼"*.jsonl "$target_dir/${latest_floor}楼"*.xz; do
              [ -f "$old_file" ] || continue
              if [[ "$old_file" != *"_old"* ]]; then
                rm "$old_file"
                echo "删除不符合保留规则的存档文件: ${old_file##*/}"
              fi
          done
      elif [ -n "$result" ] && [ "$result" -eq 1 ]; then
          echo "存档最新楼层符合保留规则，保留文件"
      elif [ -n "$result" ] && [ "$result" -eq 2 ]; then
          mapfile -t existing_files < <(find "$target_dir" -type f \( -name "*楼*.jsonl" -o -name "*楼*.xz" \))
          for file in "${existing_files[@]}"; do
            file_floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
            local result=$(should_save_floor "$file_floor" "$log_floor" "$target_dir")
            if [ -n "$result" ] && [ "$result" -eq 0 ]; then
              rm "$file"
            fi
          done
          echo "存档最新楼层符合保留规则，保留文件"
      fi
    elif [ "$latest_floor" -gt "$log_floor" ] && [ "$log_floor" -ne 0 ]; then
      echo "存档最新楼层高于酒馆聊天记录楼层，可能发生过回退"  
      while true; do
        read -n 1 -p "是否保留存档最新楼层 $latest_floor？ (y/n): " choice
        echo
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if [ -n "$latest_file" ]; then
              if [[ "$latest_file" == *.jsonl ]]; then
                  local old_content=$(cat "$latest_file")
                  local old_base_path="$(dirname "$latest_file")/$(basename "$latest_file" .jsonl)_old"
                  local old_file=$(get_xz_unique_filename "$old_base_path" "$old_content")
                  printf '%s' "$old_content" | xz -c > "$old_file"
                  rm "$latest_file"
                  echo "已保存存档最新楼层文件: ${old_file##*/}"
              elif [[ "$latest_file" == *.xz ]]; then
                  local old_basename=$(basename "$latest_file" .xz)
                  local old_file="${target_dir}/${old_basename}_old"
                  mv "$latest_file" "$old_file"
                  echo "已保存存档最新楼层文件: ${old_file##*/}"
              fi
              break
            fi
        elif [[ "$choice" =~ ^[Nn]$ ]]; then
          rm "$latest_file"
          echo "已删除存档最新楼层文件: ${latest_file#$target_dir/}"
          break
        else
          echo "无效输入，请输入 y 或 n"
        fi
      done
      local content=$(cat "$file")
      local base_save_name="${target_dir}/${log_floor}楼"
      local save_file=$(get_xz_unique_filename "$base_save_name" "$content")
      printf '%s' "$content" | xz -c > "$save_file"
      echo "已保存酒馆聊天记录文件: ${save_file##*/}"
    elif [ "$log_floor" -eq 0 ] && [ "$latest_floor" -gt 0 ]; then
      echo "酒馆聊天记录楼层为0，存档文件夹有内容，可能需要导入到酒馆"
      while true; do
        read -n 1 -p "是否需要导入存档到酒馆？ (y/n): " choice
        echo
        if [[ "$choice" =~ ^[Yy]$ ]]; then
          import_archive_to_tavern "$target_dir" "$latest_floor"
          break
        elif [[ "$choice" =~ ^[Nn]$ ]]; then
          echo "已取消导入存档到酒馆"
          echo "如果是误触，可以在主菜单选择导入存档到酒馆"
          break
        else
          echo "无效输入，请输入 y 或 n"
        fi
      done
    fi
  fi
}

#检查文件行数变化
check_line_count_changes(){
  local file="$1"
  local current_count=$(wc -l < "$file")
  local previous_count=${line_counts["$file"]:-0}
  local previous_latest_file=""
  local previous_content=""
  local latest_mtime=0
  local target_dir="$SAVE_BASE_DIR/$(dirname "${file#$SOURCE_DIR/}")/$(basename "$file" .jsonl)"
  mkdir -p "$target_dir"

  if [ "$INITIAL_SCAN" -eq 1 ]; then
    if [ "$current_count" -ne "$previous_count" ]; then
      line_counts["$file"]=$current_count
      return 0
    fi
    return 1
  else
    if [ "$current_count" -eq 0 ] && [ "$previous_count" -gt 0 ]; then
      if [ "$last_processed_file" != "$file" ]; then
          echo -e "当前文件：${YELLOW}${file#$SOURCE_DIR/}${RESET}"
          last_processed_file="$file"
      fi
      echo -e "${RED}检测到行数变为0，存档文件夹有内容，可能需要导入到酒馆${RESET}"
      while true; do
        read -n 1 -p "是否需要导入存档到酒馆？ (y/n): " choice
        echo
        if [[ "$choice" =~ ^[Yy]$ ]]; then
          import_archive_to_tavern "$target_dir" "$previous_count"
          break
        elif [[ "$choice" =~ ^[Nn]$ ]]; then
          echo "已取消导入存档到酒馆"
          echo "如果是误触，可以在主菜单选择导入存档到酒馆"
          break
        else
          echo "无效输入，请输入 y 或 n"
        fi
      done
      line_counts["$file"]=$current_count
      return 0
    elif [ "$current_count" -ne "$previous_count" ] && [ "$current_count" -gt 0 ]; then
      if [ "$last_processed_file" != "$file" ]; then
        echo -e "当前文件：${YELLOW}${file#$SOURCE_DIR/}${RESET}"
        last_processed_file="$file"
      fi
      echo "检测到行数变化（$previous_count -> $current_count）"
      for existing_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
          [ -f "$existing_file" ] || continue
          local mtime=$(stat -c %Y "$existing_file" 2>/dev/null || stat -f %m "$existing_file" 2>/dev/null)
          if [ "$mtime" -gt "$latest_mtime" ]; then
            latest_mtime=$mtime
            previous_latest_file="$existing_file"
          fi
      done
      if [ "$current_count" -gt 0 ]; then
        if [ "$current_count" -lt "$previous_count" ]; then
          line_reduced["$file"]=1
          line_counts["$file"]=$current_count
          if [ "$ROLLBACK_MODE" -eq 2 ]; then
            echo "使用回退模式2: 保留旧档并标记"
            local previous_basename=""
            local previous_dir=$(dirname "$previous_latest_file")
            local ex_count=0
            local floor_number=$(basename "$previous_latest_file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
            if ls "$target_dir"/${floor_number}楼_old*.xz &>/dev/null; then
              ex_count=$(ls -1 "$target_dir"/${floor_number}楼_old*.xz 2>/dev/null | wc -l)
              echo "已有${ex_count}个旧档"
            fi
            if [ "$ex_count" -gt 0 ]; then
              if [[ "$previous_latest_file" == *.jsonl ]]; then
                previous_basename="$(basename "$previous_latest_file" .jsonl)_old($ex_count).xz"
                cat "$previous_latest_file" | xz -c > "$previous_dir/$previous_basename"
                rm "$previous_latest_file" 2>/dev/null
              else
                previous_basename="$(basename "$previous_latest_file" .xz)_old($ex_count).xz"
                mv "$previous_latest_file" "$previous_dir/$previous_basename"
              fi
            else
              if [[ "$previous_latest_file" == *.jsonl ]]; then
                previous_basename="$(basename "$previous_latest_file" .jsonl)_old.xz"
                cat "$previous_latest_file" | xz -c > "$previous_dir/$previous_basename"
                rm "$previous_latest_file" 2>/dev/null
              else
                previous_basename="$(basename "$previous_latest_file" .xz)_old.xz"
                mv "$previous_latest_file" "$previous_dir/$previous_basename"
              fi
            fi
            echo "已保存旧档文件为: ${previous_basename}"
            previous_latest_file=""
          fi
          return
        else
          local is_rollback=0
          if [ "${line_reduced[$file]:-0}" -eq 1 ]; then
            is_rollback=1
            line_reduced["$file"]=0
            if [ "$ROLLBACK_MODE" -eq 3 ]; then
              echo "使用回退模式3：删除重写仅保留最新档"
            fi
          fi
        fi
      fi
      if [ "${line_reduced[$file]:-0}" -eq 0 ]; then
        local content=$(cat "$file")
        local save_file=$(get_xz_unique_filename "$target_dir/${current_count}楼" "$content")
        local status=$?
        if [ $status -ne 1 ]; then
          local should_save=$(should_save_floor "$previous_count" "$current_count" "$target_dir")
          if [ "$is_rollback" -ne 1 ] || [ "$ROLLBACK_MODE" -ne 2 ]; then
            if [ "$should_save" -eq 0 ] && [ -n "$previous_latest_file" ] && [ "$ROLLBACK_MODE" -ne 3 ]; then
              rm "$previous_latest_file"
              echo "删除前一个最新文件: ${previous_latest_file##*/}"
            elif [ "$is_rollback" -eq 1 ] && [ "$ROLLBACK_MODE" -eq 3 ]; then
              for all_file in "$target_dir"/*楼*.jsonl "$target_dir"/*楼*.xz; do
                  [ -f "$all_file" ] || continue
                  rm "$all_file"
              done
              echo "已清空之前的所有楼层文件"
            fi
          fi
          if [ "$SAVE_ARCHIVE_COUNT" != "infinite" ]; then
            mapfile -t old_files < <(find "$target_dir" -name "*楼*.xz" -type f -printf "%T@ %p\n" | sort -n | cut -d' ' -f2-)
            if [ "${#old_files[@]}" -ge "$((SAVE_ARCHIVE_COUNT-1))" ]; then
              local count=$((${#old_files[@]}+1-SAVE_ARCHIVE_COUNT))
              for ((i=0; i<count; i++)); do
                rm "${old_files[$i]}"
                echo "删除最旧的楼层文件: ${old_files[$i]##*/}"
              done
            fi
          fi
          printf '%s' "$content" | xz -c > "$save_file"
          echo "已保存楼层文件: ${save_file##*/}"
        fi
      fi
      line_counts["$file"]=$current_count
      return 0
    else
      local content=$(cat "$file")
      local save_file_1=$(get_xz_unique_filename "$target_dir/${current_count}楼" "$content")
      local status=$?
      if [ $status -ne 1 ] && [ -n "$save_file_1" ]; then
        printf '%s' "$content" | xz -c > "$save_file_1"
        if [ "$last_processed_file" != "$file" ]; then
            echo -e "当前文件：${YELLOW}${file#$SOURCE_DIR/}${RESET}"
            last_processed_file="$file"
        fi
        return 0
      fi
    fi
  fi
  return 1
}

#初始扫描
initial_scan(){
  echo "执行初始扫描..."
  INITIAL_SCAN=1
  
  mapfile -t jsonl_files < <(find "$SOURCE_DIR" -type f -name "*.jsonl")
    for file in "${jsonl_files[@]}"; do
        count=$(wc -l < "$file")
        line_counts["$file"]=$count
        mod_times["$file"]=$(stat -c %Y "$file" 2>/dev/null)
        
        file_md5s["$file"]=$(md5sum "$file" | cut -d' ' -f1)
        
        if [ "$INITIAL_SCAN_ARCHIVE" -ne 0 ]; then
            compare_log_with_archives "$file" "$count"
        fi
    done
    
    save_line_counts
    INITIAL_SCAN=0
    echo "初始扫描完成，记录了 ${#line_counts[@]} 个文件"
}

#智能扫描
smart_scan(){
  local changed_files=0
  local timestamp_file="$LOG_DIR/last_scan_timestamp"
  mapfile -t jsonl_files < <(find "$SOURCE_DIR" -type f -name "*.jsonl")

  if [ ! -f "$timestamp_file" ]; then
    touch "$timestamp_file"
    mapfile -t jsonl_files < <(find "$SOURCE_DIR" -type f -name "*.jsonl")
  else
    mapfile -t jsonl_files < <(find "$SOURCE_DIR" -type f -name "*.jsonl" -newer "$timestamp_file")
  fi
  
  touch "$timestamp_file"

  for file in "${jsonl_files[@]}"; do
    if [ -z "${line_counts[$file]}" ]; then
      count=$(wc -l < "$file")
      line_counts["$file"]=$count
      mod_times["$file"]=$(stat -c %Y "$file" 2>/dev/null)
      changed_files=$((changed_files + 1))
      continue
    fi
    if check_line_count_changes "$file"; then
      changed_files=$((changed_files + 1))
    fi
  done
  
  if [ $changed_files -gt 0 ]; then
    save_line_counts
  fi
  
  return $changed_files
}

#启动监控
start_monitoring(){
  clear
  initial_scan
  echo "保存行数记录到日志文件...(共${#line_counts[@]}条记录)"
  echo "开始监控JSONL文件变化..."
  exit_prompt
  while true; do
    smart_scan
    sleep 5
  done
}

#保留机制选择
retention_menu() {
  while true; do
    clear
    exit_prompt
    echo "===== 保留机制选择 ====="
    echo -e "当前机制为: $([ "$SAVE_MODE" = "interval" ] && echo "保留${YELLOW}${SAVE_INTERVAL}${RESET}的倍数和最新楼层" || echo "仅保留最新楼层")"
    echo "1. 保留__的倍数和最新楼层"
    echo "2. 仅保留最新楼层"
    echo "3. 返回设置菜单"
    echo
    read -n 1 -p "选择: " choice
    case "$choice" in
        1)
            SAVE_MODE="interval"
            first=$((SAVE_INTERVAL + 1))
            second=$((2 * SAVE_INTERVAL + 1))
            third=$((3 * SAVE_INTERVAL + 1))
            echo
            echo -e "提示：由于大多数卡有开场白，当前保留倍数为${YELLOW}${SAVE_INTERVAL}${RESET}，保留${first}、${second}、${third}楼……${SAVE_INTERVAL}*n+1楼"
            echo -n "请输入保留的倍数(按回车确认，直接回车使用当前保留倍数): "
            read -r new_interval
            if [[ $new_interval =~ ^[0-9]+$ && $new_interval -gt 0 ]]; then
              SAVE_INTERVAL=$new_interval
              save_config
              echo -e "已设置保留${YELLOW}${SAVE_INTERVAL}${RESET}的倍数和最新楼层"
            else
              echo "无效输入，使用默认值: ${SAVE_INTERVAL}"
            fi
            ;;
        2)
            SAVE_MODE="latest"
            save_config
            echo
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

#回退机制选择
rollback_menu() {
  while true; do
    clear
    exit_prompt
    echo "===== 回退机制选择 ====="
    echo -e "当前机制为: ${YELLOW}$([ "$ROLLBACK_MODE" -eq 1 ] && echo "删除重写覆盖旧档" || ([ "$ROLLBACK_MODE" -eq 2 ] && echo "删除重写保留每个档" || echo "删除重写仅保留最新档"))${RESET}"
    echo -e "1. 删除重写${CYAN}覆盖旧档${RESET}"
    echo -e "2. 删除重写${CYAN}保留每个档${RESET} (注意：删除前的楼层无论是否是${YELLOW}${SAVE_INTERVAL}${RESET}的倍数楼都进行保留)"
    echo -e "3. 删除重写${CYAN}仅保留最新档${RESET}（注意：仅保留新生成的楼层，其他${YELLOW}全部清空${RESET}）"
    echo "4. 返回设置菜单"
    echo
    read -n 1 -p "选择: " choice
    case "$choice" in
        1)
            ROLLBACK_MODE=1
            save_config
            echo
            echo "已设置回退机制为:删除重写覆盖旧档"
            ;;
        2)
            ROLLBACK_MODE=2
            save_config
            echo
            echo "已设置回退机制为:删除重写保留每个档"
            echo -e "注意：删除前的楼层无论是否是${YELLOW}${SAVE_INTERVAL}${RESET}的倍数楼都进行保留"
            ;;
        3)
            ROLLBACK_MODE=3
            save_config
            echo
            echo "已设置回退机制为:删除重写仅保留最新档"
            echo -e "注意：仅保留新生成的楼层，其他${YELLOW}全部清空${RESET}"
            ;;
        4)
            return
            ;;
        *)
            echo "无效选择"
            ;;
    esac
    press_any_key
  done
}

# 计算目录中文件数量
count_files_in_dir() {
    local dir="$1"
    local count=0
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        count=$((count + 1))
    done
    echo "$count"
}

#获取楼层范围
get_floor_range() {
    local dir="$1"
    local min_floor=999999
    local max_floor=0
    for file in "$dir"/*楼*.jsonl "$dir"/*楼*.xz; do
        [ -f "$file" ] || continue
        floor=$(echo "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        if [ -n "$floor" ]; then
            if [ "$floor" -lt "$min_floor" ]; then
                min_floor=$floor
            fi
            if [ "$floor" -gt "$max_floor" ]; then
                max_floor=$floor
            fi
        fi
    done
    if [ "$min_floor" -eq 999999 ]; then
        min_floor=0
        max_floor=0
    fi
    echo "$min_floor $max_floor"
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

#目录排序
sort_directories() {
    local dirs=("$@")
    local sorted_dirs=()
    local method="$SORT_METHOD"
    local order="$SORT_ORDER"
    local temp_file=$(mktemp)
    if [ "$method" = "time" ]; then
        for dir in "${dirs[@]}"; do
            local mtime=$(get_dir_latest_mtime "$dir")
            echo "${mtime}|${dir}" >> "$temp_file"
        done
        if [ "$order" = "asc" ]; then
            sort -t '|' -k1,1n "$temp_file" -o "$temp_file.sorted"
        else
            sort -t '|' -k1,1nr "$temp_file" -o "$temp_file.sorted"
        fi
        while IFS="|" read -r time path; do
            sorted_dirs+=("$path")
        done < "$temp_file.sorted"
        rm -f "$temp_file.sorted"
    else
        local eng_file="${temp_file}.eng"
        local chn_file="${temp_file}.chn"
        for dir in "${dirs[@]}"; do
            local base_name=$(basename "$dir")
            if [[ "$base_name" =~ ^[A-Za-z] ]]; then
                echo "$dir" >> "$eng_file"
            else
                echo "$dir" >> "$chn_file"
            fi
        done
        if [ -f "$eng_file" ]; then
            if [ "$order" = "asc" ]; then
                sort "$eng_file" -o "${eng_file}.sorted"
            else
                sort -r "$eng_file" -o "${eng_file}.sorted"
            fi
            
            while IFS= read -r dir; do
                sorted_dirs+=("$dir")
            done < "${eng_file}.sorted"
            rm -f "${eng_file}.sorted" "$eng_file"
        fi
        if [ -f "$chn_file" ]; then
            if [ "$order" = "asc" ]; then
                sort "$chn_file" -o "${chn_file}.sorted"
            else
                sort -r "$chn_file" -o "${chn_file}.sorted"
            fi
            
            while IFS= read -r dir; do
                sorted_dirs+=("$dir")
            done < "${chn_file}.sorted"
            rm -f "${chn_file}.sorted" "$chn_file"
        fi
    fi
    rm -f "$temp_file"

    for dir in "${sorted_dirs[@]}"; do
        echo "$dir"
    done
}

#按名称搜索
search_by_name(){
  SELECTED_CHAR_NAME=""
  read -p "输入角色名称(支持模糊匹配，可用空格隔开可能的关键词，按回车确认): " search_name
  if [ -z "$search_name" ]; then
    echo "角色名称不能为空"
    press_any_key
    return 1
  fi
  search_name_lower=$(echo "$search_name" | tr '[:upper:]' '[:lower:]')
  matched_dirs=()
  while IFS= read -r dir; do
    if [ -d "$dir" ]; then
      dir_name=$(basename "$dir")
      dir_name_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')
      IFS=' ' read -ra search_words <<< "$search_name_lower"
      for word in "${search_words[@]}"; do
        if [[ "$dir_name_lower" == *"$word"* ]]; then
          matched_dirs+=("$dir")
          break
        fi
      done
    fi
  done < <(find "$SAVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  if [ ${#matched_dirs[@]} -eq 0 ]; then
    echo "没有找到匹配的角色目录"
    echo -e "${YELLOW}提示：角色名可能有空格或特殊符号，可以只输入角色名的一部分${RESET}"
    press_any_key
    return 1
  fi
  echo "找到 ${#matched_dirs[@]} 个匹配结果:"
  i=0
  for dir in "${matched_dirs[@]}"; do
    char_name=$(basename "$dir")
    echo "$((++i)) - $char_name"
  done
  echo -en "选择${YELLOW}角色目录${RESET}编号[1-${#matched_dirs[@]}](按回车确认): "
  read choice
  if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#matched_dirs[@]}" ]; then
    echo "无效选择"
    press_any_key
    return 1
  fi
  selected_char_dir="${matched_dirs[$((choice-1))]}"
  char_name=$(basename "$selected_char_dir")
  SELECTED_CHAR_NAME="$char_name"
  return 0
}

#浏览角色目录
browse_folders(){
  ask_sort_method
  char_dirs=()
  SELECTED_CHAR_NAME=""
  while IFS= read -r dir; do
    if [ -d "$dir" ]; then
      char_dirs+=("$dir")
    fi
  done < <(find "$SAVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d)
  if [ ${#char_dirs[@]} -eq 0 ]; then
    echo "没有角色目录"
    press_any_key
    return 1
  fi
  while true; do
    sorted_char_dirs=()
    while IFS= read -r dir; do
      if [ -n "$dir" ]; then
        sorted_char_dirs+=("$dir")
      fi
    done < <(sort_directories "${char_dirs[@]}")
    echo "排序后目录数量: ${#sorted_char_dirs[@]}"
    i=0
    for dir in "${sorted_char_dirs[@]}"; do
      echo -e "$((++i)) - $(basename "$dir")"
    done
    echo -en "选择${YELLOW}角色目录${RESET}编号[1-${#sorted_char_dirs[@]}](按回车确认，按s切换排序顺序): "
    read choice
    if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
      if [ "$SORT_ORDER" = "asc" ]; then
        SORT_ORDER="desc"
        echo "已切换为降序排列："
      else
        SORT_ORDER="asc"
        echo "已切换为升序排列："
      fi
      save_config
      continue
    else
      break
    fi
  done
  if [[ "$choice" =~ [,[:space:]] ]]; then
    echo "当前模式下不允许多选"
    press_any_key
    return 1
  fi
  if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#sorted_char_dirs[@]}" ]; then
    echo "无效选择"
    press_any_key
    return 1
  fi
  selected_char_dir="${sorted_char_dirs[$((choice-1))]}"
  char_name=$(basename "$selected_char_dir")
  if [ -n "$char_name" ]; then
    SELECTED_CHAR_NAME="$char_name"
    return 0
  else
    return 1
  fi
}

#浏览聊天记录目录
browse_chat_folders(){
  local char_name="$1"
  local char_dir="$SAVE_BASE_DIR/$char_name"
  local rule="${2:-0}"
  BROWSE_CHAT_COUNT=0
  BROWSE_CHAT_KEYS=()

  chat_dirs=()
  i=0
  while IFS= read -r dir; do
      if [ -d "$dir" ]; then
          if [ -n "$(find "$dir" -type f 2>/dev/null)" ]; then
              chat_dirs+=("$dir")
              read floor_min floor_max < <(get_floor_range "$dir")
              total_files=$(count_files_in_dir "$dir")
              echo -e "${CYAN}$((++i)).${RESET} $(basename "$dir") (${floor_min}楼-${floor_max}楼, 共${total_files}个文件)"
          fi
      fi
  done < <(find "$char_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  
  if [ ${#chat_dirs[@]} -eq 0 ]; then
      echo "没有聊天记录目录或目录不存在: $char_dir"
      press_any_key
      return
  fi

  if [ "$rule" -eq 1 ]; then
    while true; do
      echo -en "选择${CYAN}聊天目录${RESET}编号[1-${#chat_dirs[@]}](按回车确认): "
      read choice
      echo
      if [[ "$choice" =~ [,[:space:]] ]]; then
        echo "当前模式下不允许多选"
      else
        break
      fi
    done
  else
    echo "提示：可以输入范围 (如1-5) 或输入'全选'选择所有目录"
    echo -en "选择${CYAN}聊天目录${RESET}编号[1-${#chat_dirs[@]}](按回车确认):"
    read choice
  fi

  selected_indices=($(process_range_selection "$choice" ${#chat_dirs[@]}))

  if [ ${#selected_indices[@]} -eq 0 ]; then
    echo "无效选择"
    press_any_key
    return 1
  fi

  BROWSE_CHAT_COUNT="${#selected_indices[@]}"
  
  BROWSE_CHAT_KEYS=()
  
  # 循环填充数组
  for idx in "${selected_indices[@]}"; do
      chat_dir="${chat_dirs[$((idx-1))]}"
      chat_id=$(basename "$chat_dir")
      chat_key="${char_name}/${chat_id}"
      BROWSE_CHAT_KEYS+=("$chat_key")
  done
}

#角色/聊天记录规则菜单
ch_rules_menu(){
    local type="$1"
    local key="$2"
    local rules_array
    local title
    key="${key}"
    if [ "$type" = "char" ]; then
        rules_array="CHAR_RULES"
        title="角色规则: $key"
    else
        rules_array="CHAT_RULES"
        title="${key#*/}"
    fi

  while true; do
    clear
    exit_prompt
    echo "===== $title ====="
    
    if [ "$rules_array" = "CHAR_RULES" ]; then
      if [ -z "${CHAR_RULES[$key]}" ]; then
        echo "该角色暂无自定义规则"
      else
        IFS=';' read -ra rules <<< "${CHAR_RULES[$key]}"
        for i in "${!rules[@]}"; do
          echo -n "$((i+1)). "
          display_rule "${rules[i]}" "$((i+1))"
        done
      fi
    else
      if [ -z "${CHAT_RULES[$key]}" ]; then
        echo "该聊天记录暂无自定义规则"
      else
        IFS=';' read -ra rules <<< "${CHAT_RULES[$key]}"
        for i in "${!rules[@]}"; do
          echo -n "$((i+1)). "
          display_rule "${rules[i]}" "$((i+1))"
        done
      fi
    fi

    echo "========================"
    echo "1. 新增规则"
    echo "2. 修改规则"
    echo "3. 删除规则"
    echo "4. 返回上一级"
    echo
    read -n 1 -p "选择: " choice
    echo
    case "$choice" in
      1)
        add_rule "$type" "$key"
        ;;
      2)
        if [ "$type" = "char" ]; then
          if [ -z "${CHAR_RULES[$key]}" ]; then
              echo "当前无规则可修改"
              press_any_key
              continue
          fi
          
          IFS=';' read -ra rules <<< "${CHAR_RULES[$key]}"
        else
          if [ -z "${CHAT_RULES[$key]}" ]; then
              echo "当前无规则可修改"
              press_any_key
              continue
          fi
          
          IFS=';' read -ra rules <<< "${CHAT_RULES[$key]}"
        fi
        
        if [ ${#rules[@]} -eq 0 ]; then
            echo "当前无规则可修改"
            press_any_key
            continue
        fi
        
        read -p "选择要修改的规则编号[1-${#rules[@]}]: " rule_idx
        if [[ $rule_idx =~ ^[0-9]+$ ]] && [ "$rule_idx" -ge 1 ] && [ "$rule_idx" -le "${#rules[@]}" ]; then
            edit_rule "$type" "$key" "$((rule_idx-1))"
        else
            echo "无效的规则编号"
            press_any_key
        fi
        ;;
      3)
        if [ "$type" = "char" ]; then
          if [ -z "${CHAR_RULES[$key]}" ]; then
              echo "当前无规则可删除"
              press_any_key
              continue
          fi
          
          IFS=';' read -ra rules <<< "${CHAR_RULES[$key]}"
        else
          if [ -z "${CHAT_RULES[$key]}" ]; then
              echo "当前无规则可删除"
              press_any_key
              continue
          fi
          
          IFS=';' read -ra rules <<< "${CHAT_RULES[$key]}"
        fi
        
        if [ ${#rules[@]} -eq 0 ]; then
            echo "当前无规则可删除"
            press_any_key
            continue
        fi

        echo -n "选择要删除的规则编号[1-${#rules[@]}]: "
        echo "可以输入："
        echo "- 序号范围（如 1-3）"
        echo "- 逗号分隔的序号（如 1,3,5）"
        echo "- 混合使用（如 1-3,5,7-9）"
        echo "- 输入“全选”删除所有规则"
        read -p "输入要删除的规则: " range

        local selected_indices=()
        selected_indices=($(process_range_selection "$range" ${#rules[@]}))
        if [ ${#selected_indices[@]} -eq 0 ]; then
            echo "未选择任何有效规则，取消删除操作"
        else
            IFS=$'\n' selected_indices=($(sort -nr <<<"${selected_indices[*]}"))
            unset IFS
            echo "即将删除以下规则："
            for idx in "${selected_indices[@]}"; do
                display_rule "${rules[$((idx-1))]}" "$idx"
            done
            
            read -p "确认删除? (y/n): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                new_rules=()
                for i in "${!rules[@]}"; do
                    keep=true
                    for del_idx in "${selected_indices[@]}"; do
                        if [ $((i+1)) -eq "$del_idx" ]; then
                            keep=false
                            break
                        fi
                    done
                    if [ "$keep" = true ]; then
                        new_rules+=("${rules[i]}")
                    fi
                done
                
                if [ ${#new_rules[@]} -eq 0 ]; then
                    # 清空规则
                    if [ "$type" = "char" ]; then
                        unset "CHAR_RULES[$key]"
                    else
                        unset "CHAT_RULES[$key]"
                    fi
                else
                    # 更新规则
                    rules_str=$(IFS=';'; echo "${new_rules[*]}")
                    if [ "$type" = "char" ]; then
                        CHAR_RULES["$key"]="$rules_str"
                    else
                        CHAT_RULES["$key"]="$rules_str"
                    fi
                fi
                
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

#全局规则菜单
global_rules_menu(){
  while true; do
    clear
    exit_prompt
    echo "===== 全局规则 ====="
    local index=1
    
    if [ ${#GLOBAL_RULES[@]} -eq 0 ]; then
      echo "当前无全局规则"
    else
      for rule in "${GLOBAL_RULES[@]}"; do
        echo -n "$index. "
        display_rule "$rule" "$index" "compact"
        index=$((index+1))
      done
    fi
    echo "========================"
    echo -e "1. 新增规则"
    echo -e "2. 修改规则"
    echo -e "3. 删除规则"
    echo -e "4. 返回设置菜单"
    echo
    read -n 1 -p "选择: " choice
    echo
    case "$choice" in
      1)
        add_rule "global"
        ;;
      2)
        if [ ${#GLOBAL_RULES[@]} -eq 0 ]; then
          echo "暂无规则可修改"
          press_any_key
          continue
        fi
        read -p "选择要修改的规则编号[1-${#GLOBAL_RULES[@]}]: " rule_idx
        if [[ $rule_idx =~ ^[0-9]+$ ]] && [ "$rule_idx" -ge 1 ] && [ "$rule_idx" -le "${#GLOBAL_RULES[@]}" ]; then
          edit_rule "global" "$((rule_idx-1))"
        else
          echo "无效的规则编号"
          press_any_key
        fi
        ;;
      3)
        if [ ${#GLOBAL_RULES[@]} -eq 0 ]; then
          echo "暂无规则可删除"
          press_any_key
          continue
        fi
        echo -n "选择要删除的规则编号[1-${#GLOBAL_RULES[@]}]: "
        echo "可以输入："
        echo "- 序号范围（如 1-3）"
        echo "- 逗号分隔的序号（如 1,3,5）"
        echo "- 混合使用（如 1-3,5,7-9）"
        echo "- 输入'全选'删除所有规则"
        read -p "输入要删除的规则: " range
        
        local selected_indices=()
        selected_indices=($(process_range_selection "$range" ${#GLOBAL_RULES[@]}))
        if [ ${#selected_indices[@]} -eq 0 ]; then
          echo "未选择任何有效规则，取消删除操作"
        else
          IFS=$'\n' selected_indices=($(sort -nr <<<"${selected_indices[*]}"))
          unset IFS
          echo "即将删除以下规则："
          for idx in "${selected_indices[@]}"; do
            local rule_idx=$((idx-1))
            if [ -n "${GLOBAL_RULES[$rule_idx]}" ]; then
              display_rule "${GLOBAL_RULES[$rule_idx]}" "$idx" "compact"
            fi
          done
          
          read -p "确认删除? (y/n): " confirm
          if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            for idx in "${selected_indices[@]}"; do
              unset 'GLOBAL_RULES[$((idx-1))]'
            done
            GLOBAL_RULES=("${GLOBAL_RULES[@]}")
            save_rules
            echo "已删除选定的规则"
          else
            echo "取消删除操作"
            selected_indices=()
            press_any_key
            continue
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

#局部规则菜单
local_rules_menu(){
  while true; do
    clear
    exit_prompt
    echo "===== 局部规则 ====="
    echo -e "${YELLOW}角色规则:${RESET}"
    if [ ${#CHAR_RULES[@]} -eq 0 ]; then
      echo "当前无角色规则"
    else
      local char_index=1
      for char_name in "${!CHAR_RULES[@]}"; do
        local rule_index=1
        echo -e "${CYAN}$char_index. $char_name:${RESET}"
        IFS=';' read -ra char_rules_array <<< "${CHAR_RULES[$char_name]}"
        for rule in "${char_rules_array[@]}"; do
          echo -n "($rule_index) "
          display_rule "$rule" "$rule_index" "compact"
          rule_index=$((rule_index+1))
        done
        char_index=$((char_index+1))
      done
    fi
    echo "========================"
    echo -e "${YELLOW}聊天记录规则:${RESET}"
    if [ ${#CHAT_RULES[@]} -eq 0 ]; then
      echo "当前无聊天记录规则"
    else
      local chat_index=1
      for chat_key in "${!CHAT_RULES[@]}"; do
        local rule_index=1
        echo -e "${CYAN}$chat_index. $chat_key:${RESET}"
        IFS=';' read -ra chat_rules_array <<< "${CHAT_RULES[$chat_key]}"
        for rule in "${chat_rules_array[@]}"; do
          echo -n "($rule_index) "
          display_rule "$rule" "$rule_index" "compact"
          rule_index=$((rule_index+1))
        done
        chat_index=$((chat_index+1))
      done
    fi
    echo "========================"
    echo "1. 选择文件夹"
    echo "2. 输入角色名称"
    echo "3. 管理已有规则"
    echo "4. 返回上一级"
    echo
    read -n 1 -p "选择: " choice
    echo
    case "$choice" in
      1)
        browse_folders
        if [ $? -eq 0 ]; then
          while true; do
            echo "1. 对该角色起效"
            echo "2. 对单独聊天记录起效"
            read -n 1 -p "选择(1/2): " choice
            echo
            if [ "$choice" = "1" ]; then
              char_name="$SELECTED_CHAR_NAME"
              ch_rules_menu "char" "$char_name"
              break
            elif [ "$choice" = "2" ]; then
              char_name="$SELECTED_CHAR_NAME"
              browse_chat_folders "$char_name" 1
              if [ $? -eq 0 ]; then
                  count="$BROWSE_CHAT_COUNT"
                  chat_key="${BROWSE_CHAT_KEYS[0]}"
                  ch_rules_menu "chat" "${chat_key}"
              fi
              break
            elif [ -z "$choice" ]; then
              echo "取消操作"
              press_any_key
              break
            else
              echo "无效选择，请输入1或2"
            fi
          done
        fi
        ;;
      2)
        search_by_name
        if [ $? -eq 0 ]; then
          while true; do
            echo "1. 对该角色起效"
            echo "2. 对单独聊天记录起效"
            read -n 1 -p "选择(1/2): " choice
            echo
            if [ "$choice" = "1" ]; then
              char_name="$SELECTED_CHAR_NAME"
              ch_rules_menu "char" "$char_name"
              break
            elif [ "$choice" = "2" ]; then
              char_name="$SELECTED_CHAR_NAME"
              browse_chat_folders "$char_name" 1
              if [ $? -eq 0 ]; then
                  count="$BROWSE_CHAT_COUNT"
                  chat_key="${BROWSE_CHAT_KEYS[0]}"
                  ch_rules_menu "chat" "$chat_key"
              fi
              break
            elif [ -z "$choice" ]; then
                echo "取消操作"
                press_any_key
                break
            else
                echo "无效选择，请输入1或2"
            fi
          done
        fi
        ;;
      3)
        if [ ${#CHAR_RULES[@]} -eq 0 ] && [ ${#CHAT_RULES[@]} -eq 0 ]; then
          echo "当前无规则可管理"
          press_any_key
          continue
        fi
        echo "1. 修改规则"
        echo "2. 删除规则"
        echo "3. 返回上一级"
        read -n 1 -p "选择: " choice
        echo
        case "$choice" in
          1)
            echo "提示：规则类型 (1=角色规则, 2=聊天记录规则)"
            echo -n "示例：1:1.1即"
            if [ ${#CHAR_RULES[@]} -ne 0 ]; then
              local first_char_key=$(echo "${!CHAR_RULES[@]}" | awk '{print $1}')
              echo -ne "${CYAN}1. $first_char_key:"
              IFS=';' read -ra char_rules_array <<< "${CHAR_RULES[$first_char_key]}"
              echo -ne "(1)"
              display_rule "${char_rules_array[0]}" "1" "compact"
              echo -ne "${RESET}"
            else
              echo "第一个角色的第一个规则"
            fi
            while true; do
              read -p "请输入要修改的规则编号[1-${#rules[@]}](回车确认，直接回车取消，不可多选）: " selection
              local invalid_input=0
              if [ -z "$selection" ]; then
                echo "取消操作"
                press_any_key
                break
              fi
              selection=${selection//：/:}
              IFS=':' read -ra selection_array <<< "$selection"
              unset IFS
              if [ ${#selection_array[@]} -eq 2 ]; then
                local type=${selection_array[0]}
                local rule=${selection_array[1]}
                IFS='.' read -ra rule_array <<< "$rule"
                unset IFS
                if [ ${#rule_array[@]} -eq 2 ]; then
                  local ch_idx=${rule_array[0]}
                  local rule_idx=${rule_array[1]}
                if [ $type -eq 1 ]; then
                  local ch_name=$(echo "${!CHAR_RULES[@]}" | tr ' ' '\n' | sed -n "${ch_idx}p")
                  edit_rule "char" "$ch_name" "$((rule_idx-1))"
                  break
                elif [ $type -eq 2 ]; then
                  local chat_id=$(echo "${!CHAT_RULES[@]}" | tr ' ' '\n' | sed -n "${ch_idx}p")
                  edit_rule "chat" "$chat_id" "$((rule_idx-1))"
                  break
                fi
                else
                  echo "无效输入"
                  press_any_key
                  continue
                fi
              else
                echo "无效输入"
                press_any_key
                continue
              fi
            done
            ;;
          2)
            echo "提示：规则类型 (1=角色规则, 2=聊天记录规则)"
            echo -n "示例：1:1.1即"
            if [ ${#CHAR_RULES[@]} -ne 0 ]; then
              local first_char_key=$(echo "${!CHAR_RULES[@]}" | awk '{print $1}')
              echo -ne "${CYAN}1. $first_char_key:"
              IFS=';' read -ra char_rules_array <<< "${CHAR_RULES[$first_char_key]}"
              echo -ne "(1)"
              display_rule "${char_rules_array[0]}" "1" "compact"
              echo -ne "${RESET}"
            else
              echo "第一个角色的第一个规则"
            fi
            echo "可以多选，同类型可以用逗号分割，不同类型用分号分割"
            echo -e "${YELLOW}如：1:1.1,1.2,1.3;2:1.2,2.4${RESET}"
            echo "输入"全选"即可全选"
            while true; do
              read -p "请输入要删除的规则编号[1-${#rules[@]}](回车确认，直接回车取消）: " selection
              local invalid_input=0
              if [ -z "$selection" ]; then
                echo "取消操作"
                press_any_key
                break
              fi
              if [ "$selection" = "全选" ]; then
                echo "即将删除所有规则"
                read -p "确认删除? (y/n): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                  unset "CHAR_RULES"
                  unset "CHAT_RULES"
                  save_rules
                  echo "所有规则已删除"
                  press_any_key
                  break
                else
                  echo "取消删除操作"
                  press_any_key
                  invalid_input=1
                  continue
                fi
              fi
              selection=${selection//，/,}
              selection=${selection//；/;}
              selection=${selection//：/:}
              IFS=';' read -ra selection_array <<< "$selection"
              unset IFS
              for idx in "${selection_array[@]}"; do
                IFS=':' read -ra idx_array <<< "$idx"
                unset IFS
                if [ ${#idx_array[@]} -eq 2 ]; then
                  local type=${idx_array[0]}
                  if [ $type -eq 1 ]; then
                    local type_rule=$CHAR_RULES
                  elif [ $type -eq 2 ]; then
                    local type_rule=$CHAT_RULES
                  fi
                  local rule=${idx_array[1]}
                  local names=()
                  local rules=()
                  IFS=',' read -ra rule_idx_array <<< "$rule"
                  unset IFS
                  for i in "${rule_idx_array[@]}"; do
                    IFS='.' read -ra pos_array <<< "$i"
                    unset IFS
                    if [ ${#pos_array[@]} -eq 2 ]; then
                      local ch_idx=${pos_array[0]}
                      if [ $type -eq 1 ]; then
                        local ch_keys=()
                        for key in "${!CHAR_RULES[@]}"; do
                          ch_keys+=("$key")
                        done
                        local ch_name="${ch_keys[$((ch_idx-1))]}"
                        IFS=';' read -ra ch_rules_array <<< "${CHAR_RULES[$ch_name]}"
                      elif [ $type -eq 2 ]; then
                        for key in "${!CHAT_RULES[@]}"; do
                          ch_keys+=("$key")
                        done
                        local ch_name="${ch_keys[$((ch_idx-1))]}"
                        IFS=';' read -ra ch_rules_array <<< "${CHAT_RULES[$ch_name]}"
                      fi
                      unset IFS
                      local rule_idx=${pos_array[1]}
                      local selected_rule="${ch_rules_array[$((rule_idx-1))]}"
                      names+=("$ch_name")
                      rules+=("$selected_rule")
                    else
                      echo "无效输入"
                      press_any_key
                      invalid_input=1
                      break
                    fi
                  done
                else
                  echo "无效输入"
                  press_any_key
                  invalid_input=1
                  break
                fi
              done
              [ $invalid_input -eq 1 ] && continue
              echo "即将删除以下规则："
              for ((i=0; i<${#names[@]}; i++)); do
                local name="${names[$i]}"
                local rule="${rules[$i]}"
                echo -n "${name}："
                display_rule "$rule" "1" "compact"
              done
              read -p "确认删除这些规则？(y/n): " confirm
              if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                for ((i=0; i<${#names[@]}; i++)); do
                  local name="${names[$i]}"
                  local rule="${rules[$i]}"
                  if [ $type -eq 1 ]; then
                    IFS=';' read -ra current_rules <<< "${CHAR_RULES[$name]}"
                    unset IFS
                    new_rules=()
                    for r in "${current_rules[@]}"; do
                      if [ "$r" != "$rule" ]; then
                        new_rules+=("$r")
                      fi
                    done
                    if [ ${#new_rules[@]} -eq 0 ]; then
                      unset "CHAR_RULES[$name]"
                    else
                      CHAR_RULES["$name"]=$(IFS=';'; echo "${new_rules[*]}")
                    fi
                  else
                    IFS=';' read -ra current_rules <<< "${CHAT_RULES[$name]}"
                    unset IFS
                    new_rules=()
                    for r in "${current_rules[@]}"; do
                      if [ "$r" != "$rule" ]; then
                        new_rules+=("$r")
                      fi
                    done
                    
                    if [ ${#new_rules[@]} -eq 0 ]; then
                      unset "CHAT_RULES[$name]"
                    else
                      CHAT_RULES["$name"]=$(IFS=';'; echo "${new_rules[*]}")
                    fi
                  fi
                done
                
                save_rules
                echo "规则删除成功！"
                press_any_key
                break
              else
                echo "取消删除"
                press_any_key
                break
              fi
            done
            ;;
        esac
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

#自定义规则
rules_menu() {
  while true; do
    clear
    exit_prompt
    echo "===== 自定义规则 ====="
    echo -e "${YELLOW}全局规则:${RESET}"
    local index=1
    
    if [ ${#GLOBAL_RULES[@]} -eq 0 ]; then
      echo "当前无全局规则"
    else
      for rule in "${GLOBAL_RULES[@]}"; do
        echo -n "$index. "
        display_rule "$rule" "$index" "compact"
        index=$((index+1))
      done
    fi
    echo "----------------------"
    echo -e "${YELLOW}局部规则:${RESET}"
    echo -e "${CYAN}角色规则:${RESET}"
    if [ ${#CHAR_RULES[@]} -eq 0 ]; then
      echo "当前无角色规则"
    else
      local char_index=1
      for char_name in "${!CHAR_RULES[@]}"; do
        local rule_index=1
        echo -e "$char_index. $char_name:"
        IFS=';' read -ra char_rules_array <<< "${CHAR_RULES[$char_name]}"
        for rule in "${char_rules_array[@]}"; do
          echo -n "($rule_index) "
          display_rule "$rule" "$rule_index" "compact"
          rule_index=$((rule_index+1))
        done
        char_index=$((char_index+1))
      done
    fi
    echo "----------------------"
    echo -e "${CYAN}聊天记录规则:${RESET}"
    if [ ${#CHAT_RULES[@]} -eq 0 ]; then
      echo "当前无聊天记录规则"
    else
      local chat_index=1
      for chat_key in "${!CHAT_RULES[@]}"; do
        local rule_index=1
        echo -e "$chat_index. $chat_key:"
        IFS=';' read -ra chat_rules_array <<< "${CHAT_RULES[$chat_key]}"
        for rule in "${chat_rules_array[@]}"; do
          echo -n "($rule_index) "
          display_rule "${CHAT_RULES[$chat_key]}" "$rule_index" "compact"
          rule_index=$((rule_index+1))
        done
        chat_index=$((chat_index+1))
      done
    fi
    echo "======================"
    echo -e "1. 全局规则"
    echo -e "2. 局部规则"
    echo -e "3. 返回设置菜单"
    echo
    read -n 1 -p "选择: " choice
    
    case "$choice" in
      1)
        global_rules_menu
        ;;
      2)
        local_rules_menu
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

#修改用户名
change_username(){
  clear
  exit_prompt
  echo "===== 修改用户名 ====="
  echo -e "当前用户名: ${YELLOW}$USERNAME${RESET}"
  echo -e "\033[38;5;9;48;5;21m重要提示：如果您不理解此设置的作用，请不要修改！${RESET}"
  echo -e "${WHITE_ON_RED}重要提示：如果您不理解此设置的作用，请不要修改！${RESET}"
  echo -e "\033[38;5;196;48;5;226m重要提示：如果您不理解此设置的作用，请不要修改！${RESET}"
  echo "此设置用于适配不同的SillyTavern用户目录。"
  echo "修改此设置会改变脚本读取和保存文件的路径。"
  echo 
  read -p "请输入新的用户名 (回车确认，直接回车取消): " new_username

  if [ -z "$new_username" ]; then
      echo "操作已取消"
      press_any_key
      return
  fi

  echo ""
  echo -e "您确定要将用户名从 ${YELLOW}\"$USERNAME\"${RESET} 改为 ${RED}\"$new_username\"${RESET} 吗？"
  echo "这将改变文件的读取和保存路径。"
  echo -n "确认修改? (y/n): "
  read -r confirm
  
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
      USERNAME="$new_username"
      
      SOURCE_DIR="${SILLY_TAVERN_DIR}/data/${USERNAME}/chats"
      SAVE_BASE_DIR="${SCRIPT_DIR}/saved-date/${USERNAME}/chats"
      
      mkdir -p "$SOURCE_DIR"
      mkdir -p "$SAVE_BASE_DIR"
      
      save_config
      
      echo "用户名已更新为: $USERNAME"
      echo "新的聊天记录路径: $SOURCE_DIR"
      echo "新的存档路径: $SAVE_BASE_DIR"
      echo ""
  else
      echo "操作已取消"
  fi
  press_any_key
}

#存档位个数选择
archive_count_menu(){
  while true; do
    clear
    exit_prompt
    echo "===== 存档位设置 ====="
    if [ "$SAVE_ARCHIVE_COUNT" = "infinite" ]; then
      echo -e "当前存档位个数: ${YELLOW}无限${RESET}"
    else
      echo -e "当前存档位个数: ${YELLOW}${SAVE_ARCHIVE_COUNT}${RESET}"
    fi
    echo "1. 输入个数"
    echo "2. 无限"
    echo "3. 返回主菜单"
    echo
    read -n 1 -p "选择: " choice
    case "$choice" in
      1)
        echo
        while true; do
          read -p "请输入存档位个数（回车确认，直接回车取消）: " SAVE_ARCHIVE_COUNT
          if [[ "$SAVE_ARCHIVE_COUNT" =~ ^[0-9]+$ ]]; then
            SAVE_ARCHIVE_COUNT=$SAVE_ARCHIVE_COUNT
            save_config
            echo "已设置为: $SAVE_ARCHIVE_COUNT个存档位"
            press_any_key
            break
          elif [ -z "$SAVE_ARCHIVE_COUNT" ]; then
            echo "取消操作"
            press_any_key
            break
          else
            echo "无效输入"
            press_any_key
          fi
        done
        break
        ;;
      2)
        echo
        SAVE_ARCHIVE_COUNT="infinite"
        save_config
        echo "已设置为: 无限存档位"
        press_any_key
        break
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

#初始扫描设置
initial_scan_menu(){
  while true; do
    clear
    exit_prompt
    echo "===== 初始扫描设置 ====="
    echo -e "当前设置: $([ "$INITIAL_SCAN_ARCHIVE" = "0" ] && echo "仅记录行数，不比对存档" || ([ "$INITIAL_SCAN_ARCHIVE" = "1" ] && echo "记录并比对存档（没有存档时${YELLOW}不生成${RESET}新存档）" || echo "记录并比对存档（没有存档时${YELLOW}生成${RESET}新存档）"))"
    echo "========================"
    echo "1. 仅记录行数，不比对存档"
    echo -e "2. 记录并比对存档（没有存档时${YELLOW}不生成${RESET}新存档）"
    echo -e "3. 记录并比对存档（没有存档时${YELLOW}生成${RESET}新存档）"
    echo -e "4. 返回主菜单"
    echo 
    read -n 1 -p "选择: " choice
    case "$choice" in
      1)
        INITIAL_SCAN_ARCHIVE=0
        echo "已设置为: 仅记录行数，不比对存档"
        save_config
        press_any_key
        break
        ;;
      2)
        INITIAL_SCAN_ARCHIVE=1
        echo -e "已设置为: 记录并比对存档（没有存档时${YELLOW}不生成${RESET}新存档）"
        save_config
        press_any_key
        break
        ;;
      3)
        INITIAL_SCAN_ARCHIVE=2
        echo -e "已设置为: 记录并比对存档（没有存档时${YELLOW}生成${RESET}新存档）"
        save_config
        press_any_key
        break
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

#设置菜单
settings_menu(){
  while true; do
        clear
        exit_prompt
        echo "===== 设置 ====="
        echo -e "1. 保留机制选择 (当前机制为: $([ "$SAVE_MODE" = "interval" ] && echo "保留${YELLOW}${SAVE_INTERVAL}${RESET}的倍数和最新楼层" || echo "仅保留最新楼层"))"
        echo -e "2. 回退机制选择 (当前机制为: $([ "$ROLLBACK_MODE" -eq 1 ] && echo "删除重写覆盖旧档" || echo "删除重写保留每个档"))"
        echo "3. 自定义规则"
        echo -e "4. 存档位设置 (当前存档位个数: $([ "$SAVE_ARCHIVE_COUNT" = "infinite" ] && echo "无限" || echo "${YELLOW}${SAVE_ARCHIVE_COUNT}${RESET}"))"
        echo -e "5. 初始扫描设置 (当前设置: $([ "$INITIAL_SCAN_ARCHIVE" = "0" ] && echo "仅记录行数，不比对存档" || ([ "$INITIAL_SCAN_ARCHIVE" = "1" ] && echo "记录并比对存档（没有存档时${YELLOW}不生成${RESET}新存档）" || echo "记录并比对存档（没有存档时${YELLOW}生成${RESET}新存档）")))"
        echo -e "6. 修改用户名 (当前用户名: ${YELLOW}${USERNAME}${RESET})"
        echo -e "7. 返回主菜单"
        echo
        read -n 1 -p "选择: " choice
        
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
                archive_count_menu
                ;;
            5)
                initial_scan_menu
                ;;
            6)
                change_username
                ;;
            7)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
  done
}

#保留特定倍数楼层
keep_floor_multiples(){
  local type=$1
  local target_dir=$2
  echo -n "请输入倍数："
  read -r save_multiple
  if [ "$type" = 1 ]; then
    echo "准备清理所有冗余存档..."
    echo "注意：这将清理所有聊天记录中的非必要楼层。"
    echo -n "输入【确认】后按回车，开始清理操作（输入其他字符或直接换行则取消）: "
    read -r confirm
    if [ "$confirm" != "确认" ]; then
        echo "操作已取消"
        press_any_key
        return
    fi
  fi
  read -p "如果文件夹中没有符合倍数的文件，是否保留最新的一个文件？(y/n): " keep_latest
  if [[ "$keep_latest" =~ ^[Nn]$ ]]; then
      keep_latest=false
      echo "如文件夹中没有符合倍数的文件，将会自动清空文件夹，是否确认？"
      read -p "输入【确认】后按回车，开始清理操作（输入其他字符或直接换行则取消）: " confirm
      if [ "$confirm" != "确认" ]; then
          echo "操作已取消"
          press_any_key
          return
      fi
  else
      keep_latest=true
  fi
  echo "开始清理冗余存档..."
  if [ "$type" = 1 ]; then
    find_path="$SAVE_BASE_DIR"
    depth_params="-mindepth 2 -maxdepth 2"
  else
    find_path="$target_dir"
    depth_params="-mindepth 1 -maxdepth 1"
  fi
  find "$find_path" $depth_params -type d | while read -r chat_dir; do
    mapfile -t floor_files < <(find "$chat_dir" \( -name "*楼*.xz" -o -name "*楼*.jsonl" \) | sort -V)
    if [ "$type" = 1 ]; then
      char_name=$(basename "$(dirname "$chat_dir")")
      chat_name=$(basename "$chat_dir")
    else
      char_name=$(basename "$target_dir")
      chat_name=$(basename "$chat_dir")
    fi
    if [ ${#floor_files[@]} -eq 0 ]; then
        continue
    fi
    declare -a keep_files
    for file in "${floor_files[@]}"; do
        floor_num=$(basename "$file" | grep -o '[0-9]\+楼' | grep -o '[0-9]\+')
        if [ $((floor_num % save_multiple)) -eq 0 ]; then
            keep_files+=("$file")
        fi
    done
    newest_file=$(find "$chat_dir" \( -name "*楼*.xz" -o -name "*楼*.jsonl" \) -type f -printf "%T@ %p\n" | sort -n | tail -n 1 | cut -d' ' -f2-)
    if [ ${#keep_files[@]} -eq 0 ] && [ "$keep_latest" = true ] && [ -n "$newest_file" ]; then
        keep_files+=("$newest_file")
        echo "${char_name}/${chat_name}没有符合倍数的文件，保留最新文件: $(basename "$newest_file")"
    fi
    for file in "${floor_files[@]}"; do
        if [[ ! " ${keep_files[*]} " =~ " $file " ]]; then
            rm "$file"
        fi
    done
  done
  echo "所有冗余存档清理完成！"
  press_any_key
}

#保留最新的__个楼层
keep_limited_floor_count(){
  local type=$1
  local target_dir=$2
  local save_count=${3:-0}
  if [ "$save_count" -eq 0 ]; then
    read -p "请输入个数(回车确认，直接回车取消）：" save_count
    echo
    if [ -z "$save_count" ]; then
      echo "操作已取消"
      press_any_key
      return
    elif ! [[ "$save_count" =~ ^[0-9]+$ ]]; then
      echo "请输入有效的数字"
      press_any_key
      return
    fi
  fi
  if [ "$type" = 1 ]; then
    depth_params="-mindepth 2 -maxdepth 2"
  else
    depth_params="-mindepth 1 -maxdepth 1"
  fi
  find "$target_dir" $depth_params -type d | while read -r chat_dir; do
    mapfile -t floor_files < <(find "$chat_dir" \( -name "*楼*.xz" -o -name "*楼*.jsonl" \) -printf "%T@ %p\n" | sort -n | cut -d' ' -f2-)
    if [ ${#floor_files[@]} -le "$save_count" ]; then
      continue
    fi    
    files_to_delete=$((${#floor_files[@]} - save_count))
    for ((i=0; i<files_to_delete; i++)); do
      rm "${floor_files[i]}"
    done
  done
  echo "所有冗余存档清理完成！"
  press_any_key
}

#清除冗余存档
cleanup_menu(){
  clear
  exit_prompt
  echo "===== 清除冗余存档 ====="
  echo "1. 全部聊天"
  echo "2. 选择文件夹"
  echo "3. 输入角色名称"
  echo "4. 返回主菜单"
  echo
  read -n 1 -p "选择：" choice
  echo
  case "$choice" in
      1)
        echo "请选择清理方式:"
        echo "1. 保留特定倍数楼层"
        echo "2. 仅保留最新楼层"
        echo "3. 仅保留最新的__个楼层"
        echo "4. 清空聊天记录"
        echo "5. 返回主菜单"
        read -n 1 -p "选择：" choice

        case "$choice" in
            1)
                echo
                keep_floor_multiples 1
                ;;
            2)
                echo
                keep_limited_floor_count 1 $SAVE_BASE_DIR 1
                ;;
            3)
                echo
                keep_limited_floor_count 1 $SAVE_BASE_DIR
                ;;
            4)
                echo
                echo -ne "${RED}警告：将会清空所有聊天记录，是否确认？(请输入"确认"): ${RESET}"
                read -r confirm
                if [ "$confirm" = "确认" ]; then
                  echo -e "${RED}该操作十分危险，将会把所有存档完全清空，是否确认？(请输入“我已知晓风险，确认”): ${RESET}"
                  read -r confirm
                  if [ "$confirm" = "我已知晓风险，确认" ]; then
                    rm -rf "$SAVE_BASE_DIR"/*
                    echo "所有聊天记录已清空"
                    press_any_key
                  else
                    echo "操作已取消"
                    press_any_key
                  fi
                else
                  echo "操作已取消"
                  press_any_key
                fi
                ;;
            5)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
        esac
        ;;
      2|3)
        if [ "$choice" = 2 ]; then
          browse_folders
        else
          search_by_name
        fi
        if [ $? -eq 0 ]; then
          echo "请选择清理方式:"
          echo "1. 保留特定倍数楼层"
          echo "2. 仅保留最新楼层"
          echo "3. 仅保留最新的__个楼层"
          echo "4. 清空聊天记录"
          echo "5. 返回主菜单"
          read -n 1 -p "选择：" choice
          echo
          case "$choice" in
            1) 
                keep_floor_multiples 2 "$SAVE_BASE_DIR/${SELECTED_CHAR_NAME}"
                ;;
            2)
                keep_limited_floor_count 2 "$SAVE_BASE_DIR/${SELECTED_CHAR_NAME}" 1
                ;;
            3)
                keep_limited_floor_count 2 "$SAVE_BASE_DIR/${SELECTED_CHAR_NAME}"
                ;;
            4)
                echo
                echo -ne "${RED}警告：将会清空${SELECTED_CHAR_NAME}的存档，是否确认？(请输入"确认"): ${RESET}"
                read -r confirm
                if [ "$confirm" = "确认" ]; then
                  echo -e "${RED}该操作十分危险，将会把${SELECTED_CHAR_NAME}的存档完全清空，是否确认？(请输入“我已知晓风险，确认”): ${RESET}"
                  read -r confirm
                  if [ "$confirm" = "我已知晓风险，确认" ]; then
                    rm -rf "$SAVE_BASE_DIR/${SELECTED_CHAR_NAME}"/*
                    echo "${SELECTED_CHAR_NAME}的存档已清空"
                    press_any_key
                  else
                    echo "操作已取消"
                    press_any_key
                  fi
                else
                  echo "操作已取消"
                  press_any_key
                fi
                ;;
            5)
                return
                ;;
            *)
                echo "无效选择"
                press_any_key
                ;;
          esac
        fi
        ;;
      4)
        return
        ;;
      *)
        echo "无效选择"
        press_any_key
        ;;
  esac
}

# 存档全部聊天记录
archive_all_chats(){
  clear
  echo "开始扫描所有聊天记录..."
  ORIGINAL_INITIAL_SCAN_ARCHIVE=$INITIAL_SCAN_ARCHIVE
  INITIAL_SCAN_ARCHIVE=2
  initial_scan
  INITIAL_SCAN_ARCHIVE=$ORIGINAL_INITIAL_SCAN_ARCHIVE
  echo "全部存档完成！"
  press_any_key
}

# 压缩全部聊天存档功能
compress_all_chats() {
  clear
  echo "正在扫描需要压缩的存档文件..."
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
      local xz_file="${file%.jsonl}.xz"
      local content=$(cat "$file")
      local skip_compression=0
      local status=0
      if [ -f "$xz_file" ]; then
        local base_name="${xz_file%.xz}"
        local save_file=$(get_xz_unique_filename "${base_name}" "$content" 1)
        local status=$?
      else
        save_file=$xz_file
      fi
      if [ $status -ne 1 ] && [ -n "$save_file" ]; then
        if printf '%s' "$content" | xz -c > "$save_file"; then
          compressed_files=$((compressed_files + 1))
          rm -f "$file"
        else
          failed_files=$((failed_files + 1))
        fi
      else
        rm -f "$file"
      fi
  done
  echo "压缩完成！"
  echo "总共处理: $total_files 个文件"
  echo "成功压缩: $compressed_files 个文件"
  if [ $failed_files -gt 0 ]; then
      echo "压缩失败: $failed_files 个文件"
  fi
  press_any_key
}

# 导入聊天记录进酒馆功能
import_chat_records(){
  clear
  exit_prompt
  echo "===== 导入聊天记录 ====="
  echo "1. 选择文件夹"
  echo "2. 输入角色名称"
  echo "3. 返回主菜单"
  while true; do
    read -n 1 -p "选择：" choice
    echo
    case "$choice" in
      1|2)
        if [ "$choice" = 1 ]; then
          browse_folders
        else
          search_by_name
        fi
        if [ $? -eq 0 ]; then
          browse_chat_folders "${SELECTED_CHAR_NAME}" 1
          if [ $? -eq 0 ]; then
            local chat_key="${BROWSE_CHAT_KEYS[0]}"
            local full_path="${SAVE_BASE_DIR}/${chat_key}"
            import_archive_to_tavern "$full_path"
          fi
        fi
        break
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

#主菜单
main_menu() {
    while true; do
        clear
        exit_prompt
        echo "作者：柳拂城"
        echo "当前版本：$VERSION"
        echo "如遇bug请在GitHub上反馈( *ˊᵕˋ)✩︎‧"
        echo "GitHub链接：https://github.com/Liu-fucheng/Jsonl_monitor（记得看Readme）"
        echo
        echo -e "首次使用请先输入\e[33m2\e[0m进入设置"
        echo -e "本次更新新增了${YELLOW}存档位设定${RESET}，默认每个聊天记录下有10个存档位，请提前进入设置修改"
        echo -e "存档将会以xz格式保存在：${YELLOW}$SAVE_BASE_DIR${RESET}"
        echo
        echo "===== JSONL自动存档工具 ====="
        echo "1. 启动"
        echo "2. 设置"
        echo "3. 更新"
        echo "4. 清除冗余存档"
        echo "5. 存档全部聊天记录"
        echo "6. 压缩全部聊天存档"
        echo "7. 导入聊天记录进酒馆"
        echo "8. 退出"
        echo
        read -n 1 -p "选择: " choice
        
        case "$choice" in
            1)
                start_monitoring
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

trap 'cleanup_on_exit 130' INT TERM HUP
trap 'cleanup_on_exit 0' EXIT

#主函数
main() {
    check_for_updates
    load_config
    initialize_directories
    load_rules
    check_for_updates
    main_menu
}

main
