## 简要介绍

Jsonl.sh是为SillyTavern写的自动存档脚本，可以设置“保留特定数字的倍数和最新楼层”“仅保留最新楼层”，防止丢失酒馆聊天记录。

## 安装及更新

### 安装

在termux输入：

* 直连：`git clone "https://github.com/Liu-fucheng/Jsonl_monitor.git"`
* 国内源：`curl -O "https://ghproxy.com/raw.githubusercontent.com/Liu-fucheng/Jsonl_monitor/main/jsonl.sh"`

### 更新

可直接在脚本内更新或输入以上代码更新

## 使用说明

### 主菜单

#### 启动

启动监控，执行初始扫描（会扫描本地酒馆内的所有聊天记录文件），记录聊天行数，比对本地存档（默认不开启）。
