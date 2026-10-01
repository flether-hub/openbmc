# 该配方没有版本后缀，因此必须使用不带 _% 的 bbappend 文件名。
# 上电恢复策略的出厂默认值为 Restore（恢复断电前状态）。
# 用户可在 Web 界面中改为 AlwaysOn / AlwaysOff / Restore，设置会被持久化。
do_install:append:ceb-gnrd() {
    sed -i \
        's/Default: RestorePolicy::Policy::AlwaysOff/Default: RestorePolicy::Policy::Restore/g' \
        ${D}${settings_datadir}/defaults.yaml
}
