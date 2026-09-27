# 该配方没有版本后缀，因此必须使用不带 _% 的 bbappend 文件名。
# CEB-GNRD 上电后恢复上一次主机电源状态。
do_install:append:ceb-gnrd() {
    sed -i \
        's/Default: RestorePolicy::Policy::AlwaysOff/Default: RestorePolicy::Policy::AlwaysOn/g' \
        ${D}${settings_datadir}/defaults.yaml
}
