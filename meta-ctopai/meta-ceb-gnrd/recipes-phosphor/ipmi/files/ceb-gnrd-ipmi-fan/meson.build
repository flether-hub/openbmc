project(
    'ceb-gnrd-ipmi-fan',
    'cpp',
    version: '1.0',
    default_options: ['cpp_std=c++23', 'warning_level=2'],
)

shared_library(
    'cebgnrdfancmd',
    'fan_oem.cpp',
    dependencies: [
        dependency('libipmid'),
        dependency('sdbusplus'),
        dependency('phosphor-logging'),
    ],
    override_options: 'b_lundef=false',
    version: meson.project_version(),
    install: true,
    install_dir: get_option('libdir') / 'ipmid-providers',
)