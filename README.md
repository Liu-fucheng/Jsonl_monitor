## 简要介绍

jsonl.sh是为SillyTavern写的自动存档脚本，只支持安卓，可以设置“保留特定数字的倍数和最新楼层”“仅保留最新楼层”，防止丢失酒馆聊天记录。可在脚本内清理存档，也可直接在脚本内导入存档（已将存档压缩成xz文件，推荐脚本内直接导入）至酒馆。

**自定义规则基本没有测试，如有bug请随时反馈！**

如果有问题随时反馈，非常感谢~

## 安装及更新

### 安装

在termux输入：

* 直连：`curl -O https://raw.githubusercontent.com/Liu-fucheng/Jsonl_monitor/main/jsonl.sh`
* 国内源：`curl -O "https://ghproxy.com/raw.githubusercontent.com/Liu-fucheng/Jsonl_monitor/main/jsonl.sh"`

### 更新

可直接在脚本内更新或输入以上代码更新

## 使用说明

（如正在运行一键脚本，需先退出原有脚本）在termux输入：`bash jsonl.sh`进入脚本

### 启动

启动监控，执行[初始扫描](#5初始扫描设置)（会扫描本地酒馆内的所有聊天记录文件），记录聊天行数，比对本地存档（默认不开启）。

**初次扫描没有进度条，一般不会卡住，只是在执行处理。**

**一般不会卡住，一般不会卡住，一般不会卡住。**

初始扫描执行完毕后会实时扫描本地文件，记录聊天行数，按照设置中的规则保存存档。

### 设置（必看！）

#### 1.保留机制选择

* `保留__的倍数和最新楼层`
* `仅保留最新楼层`
  
默认为保留20楼的倍数和最新楼层，由于大多数卡有开场白，默认保留的是20*n+1楼（即保留21、41、61楼）。

如楼层较高可将数字拉大，如每100楼保留一次，楼层非常高（几千楼）可以在[自定义规则](#3自定义规则)中针对角色/聊天记录进行单独设置。



#### 2.回退处理选择

* `删除重写仅保留最新档（默认，减少占用内存）`
  
  删除楼层后重新生成（包括直接在酒馆内点“重新生成”而不是下一页）都只保留最新档，不保留旧档。
  
* `删除重写保留每个档（删除前的楼层无论是否符合保留机制均保留）`
  
  删除楼层后重新生成（包括直接在酒馆内点“重新生成”而不是下一页）保留每一个档，旧档会添加_old的后缀保存，如需删除可在mt管理器手动删除或清除冗余存档中清除。

#### 3.自定义规则

*未完整测试，bug可能非常多*

* `全局规则`
* `文件夹局部规则`
  
  * 角色规则（只对该角色起效）
  * 聊天记录规则（只对该聊天记录起效）

规则可为`__楼以上只保留最近__楼内__的倍数`和`__楼以上只保留最新楼层`

#### 4.修改用户名

*看不懂说明不是给你改的！看不懂说明不是给你改的！看不懂说明不是给你改的！*

提供给启用了多账户功能的用户使用

#### 5.初始扫描设置

* `仅记录行数，不对比存档（默认）`
  
  优点是很快。
  
* `记录并对比存档（没有存档时不生成新存档）`
  
  如果存档存在且酒馆文件与存档文件匹配不上，生成新的存档，如果酒馆文件被清空，询问是否导入已有存档进酒馆。导入成功后只需要*管理聊天文件*或*切换角色卡*等重新进入聊天即可。
  
  如果存档不存在，不生成存档。（避免耗时太长）
  
* `记录并对比存档（没有存档时生成新存档）（耗时最长）`
  
  如果存档存在且酒馆文件与存档文件匹配不上，生成新的存档，如果酒馆文件被清空，询问是否导入已有存档进酒馆。导入成功后只需要*管理聊天文件*或*切换角色卡*等重新进入聊天即可。
  
  如果存档不存在（指在使用该脚本之前新开了存档），生成新存档。
  
  **不推荐**一开始就选择这个，除非已在主菜单保存全部聊天存档，否则*初次扫描会看起来像卡住*了。
  

### 更新

更新。

### 清除冗余存档

* `全部聊天`
  不用担心，选择之后不会立刻把全部聊天都删掉的。
* `选择文件夹`
* `输入角色名称`

清理方式：`清理楼层范围`和`保留特定倍数楼层`。
在这里你可以清除掉带_old后缀的文件。

### 存档全部聊天记录

存档全部聊天记录。

### 压缩全部聊天存档

压缩全部聊天存档。

是给使用之前版本的脚本的朋友使用的，但是你也可以输入这个，什么都不会发生。

### 导入聊天记录进酒馆

输入角色名搜索目录，选择聊天记录目录，选择楼层，可选择覆盖原有记录/新建聊天记录（会加上_imported的后缀，模拟酒馆导入）。

不通过脚本导入的方法：在目录中找到你需要的xz文件，解压成jsonl文件，在酒馆内导入。（但是为什么不用脚本导入呢！）

## Q&A

Q：没有保存到修改后的文件怎么办？

A：由于此脚本的原理是扫描酒馆聊天文件并另存为，如果酒馆后台卡住没有保存成功修改，脚本不能捕捉到修改，不会生成存档。

   可以尝试的解决办法：酒馆左下角-保存检查点，会生成名为Checkpoint…….jsonl的新文件。
