# 单条事件删除与状态开关（2026-10-06）

用户浏览器证据：单条 EventLog DELETE 返回 405。固定 bmcweb 提交
09f5d7becdbefa97688a065c649d0124dffc653f 的文件日志路由仅有 GET，没有 DELETE。

修改限于 CEB-GNRD 固件：

- webui-vue 的 production 环境启用已有 VITE_EVENT_LOGS_TOGGLE_BUTTON_DISABLED，
  去掉 Resolved/Unresolved 列及状态筛选，不改变其他删除、导出操作。
- bmcweb 增加 Systems/Managers 文件事件日志的单条 DELETE，使用 deleteLogEntry
  权限与标准路由鉴权。未找到或已删除的 ID 返回 404；成功返回 204；I/O 失败返回错误。
- 删除时原位覆盖该行的消息和参数为 #DEL 与空格，保留时间戳及行长度作为 ID
  占位。GET 与列表跳过占位，分页计数不包含占位；同秒其他事件的 ID 不重新编号。
  不截断或替换 rsyslog 正在写的文件，不重启日志服务。打开文件禁止跟随符号链接，
  写入并 fflush/fsync 后才返回成功。
- 这是 Redfish 文件事件记录的删除；不会删除其他后端保留的 journal/IPMI SEL 副本，
  不会清除传感器实际故障。占位空间由正常轮转或 ClearLog 回收。

补丁：recipes-phosphor/interfaces/files/0001-ceb-gnrd-delete-single-file-event-log.patch。
需要重新构建 bmcweb 和 webui-vue 并更新固件；不是模拟器修改。
未编译、未运行测试。用户需验证删除、刷新、同秒多记录、分页、重启、轮转和权限。

用户构建发现 fclose 函数指针作为 unique_ptr 模板参数触发
-Werror=ignored-attributes。已改为 lambda deleter，保留自动 fclose，
不关闭编译警告。更新补丁应用检查通过；修正后的编译仍由用户执行。
