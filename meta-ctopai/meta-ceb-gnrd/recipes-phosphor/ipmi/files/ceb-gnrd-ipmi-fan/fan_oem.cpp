// SPDX-License-Identifier: Apache-2.0
//
// CEB-GNRD OEM IPMI commands for fan control (OEM netfn 0x30).
//
// The library only forwards to the D-Bus service ceb-gnrd-fan-settings, which
// holds the fan control logic.  Two commands cover everything the web page does:
//
//   0x01  Get fan status
//         request : none
//         response: byte 0      keep the settings after a BMC reboot (0/1)
//                   then, for SYS_FAN0 .. SYS_FAN5, 4 bytes each:
//                     control mode  0 = adaptive, 1 = fixed speed
//                     duty in percent (0xFF = unknown)
//                     speed in RPM, low byte, high byte
//   0x02  Set fan control
//         request : fan      0..5 = one fan, 0xFF = all fans
//                   mode     0 = adaptive, 1 = fixed speed
//                   duty     10..100 percent, used in fixed mode
//                   persist  0 / 1 = keep the settings after a BMC reboot
//         response: none
//
// ipmitool raw 0x30 0x01
// ipmitool raw 0x30 0x02 0xFF 0x01 0x3C 0x01   (all fans fixed at 60 %, keep)

#include <ipmid/api.hpp>
#include <phosphor-logging/lg2.hpp>

#include <cstdint>
#include <string>
#include <vector>

void registerCebGnrdFanCommands() __attribute__((constructor));

namespace
{
constexpr auto fanService = "xyz.openbmc_project.CebGnrd.FanSettings";
constexpr auto fanPath = "/xyz/openbmc_project/ceb_gnrd/fan_settings";
constexpr auto fanInterface = "xyz.openbmc_project.CebGnrd.FanSettings";

constexpr ipmi::Cmd cmdGetFans = 0x01;
constexpr ipmi::Cmd cmdSetFan = 0x02;
} // namespace

ipmi::RspType<std::vector<uint8_t>> ipmiCebGnrdGetFans(ipmi::Context::ptr ctx)
{
    boost::system::error_code ec;
    auto data = ctx->bus->yield_method_call<std::vector<uint8_t>>(
        ctx->yield, ec, fanService, fanPath, fanInterface, "GetFans");
    if (ec)
    {
        lg2::error("GetFans failed: {ERROR}", "ERROR", ec.message());
        return ipmi::responseResponseError();
    }
    return ipmi::responseSuccess(std::move(data));
}

ipmi::RspType<> ipmiCebGnrdSetFan(ipmi::Context::ptr ctx, uint8_t fan,
                                  uint8_t mode, uint8_t duty, uint8_t persist)
{
    boost::system::error_code ec;
    bool ok = ctx->bus->yield_method_call<bool>(
        ctx->yield, ec, fanService, fanPath, fanInterface, "SetFan", fan, mode,
        duty, persist);
    if (ec)
    {
        lg2::error("SetFan failed: {ERROR}", "ERROR", ec.message());
        return ipmi::responseResponseError();
    }
    if (!ok)
    {
        return ipmi::responseInvalidFieldRequest();
    }
    return ipmi::responseSuccess();
}

void registerCebGnrdFanCommands()
{
    ipmi::registerHandler(ipmi::prioOemBase, ipmi::netFnOemOne, cmdGetFans,
                          ipmi::Privilege::User, ipmiCebGnrdGetFans);
    ipmi::registerHandler(ipmi::prioOemBase, ipmi::netFnOemOne, cmdSetFan,
                          ipmi::Privilege::Admin, ipmiCebGnrdSetFan);
}