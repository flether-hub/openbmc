#!/usr/bin/env python3
"""Bounded firmware checks; metadata checks never imply end-to-end success."""
import base64
from collections import Counter
import json
import math
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

OUT = Path('/tmp/ceb-gnrd-check')
FILE_LIMIT = 256 * 1024
REPORT_LIMIT = 2 * 1024 * 1024
BUNDLE_LIMIT = 4 * 1024 * 1024
POST_PAGE_SIZE = 32
POST_ENTRY_LIMIT = 1024  # two retained boots, at most 512 records per boot
PASSWORD = os.environ.get('BMC_PASSWORD', '0penBmc')
ENV = 'qemu' if sys.argv[1] == '0' else 'board'
COUNT = Counter()
RESULTS = []
HOST = None
if OUT.is_symlink() or (OUT.exists() and not OUT.is_dir()):
    raise SystemExit('Unsafe output path: /tmp/ceb-gnrd-check')
if OUT.exists():
    shutil.rmtree(OUT)
OUT.mkdir(mode=0o700)
REPORT = OUT / 'report.txt'


def redact(text):
    return str(text).replace(PASSWORD, '<redacted>') if PASSWORD else str(text)


def record(text):
    size = REPORT.stat().st_size if REPORT.exists() else 0
    # Reserve the last 8 KiB for results/summary.
    if size < REPORT_LIMIT - 8192:
        with REPORT.open('ab') as stream:
            stream.write((redact(text) + '\n').encode()[:min(FILE_LIMIT, REPORT_LIMIT-8192-size)])


def result(status, name, detail=''):
    COUNT[status] += 1
    RESULTS.append({'status': status, 'name': name, 'detail': redact(detail)})
    line = f'[{status}] {name}' + (': ' + str(detail) if detail else '')
    print(redact(line), flush=True)
    record(line)


def require(name, condition, detail=''):
    result('PASS' if condition else 'FAIL', name, detail)


def section(name):
    print('\n===== ' + name + ' =====', flush=True)
    record('\n===== ' + name + ' =====')


def child_limits():
    resource.setrlimit(resource.RLIMIT_FSIZE, (FILE_LIMIT, FILE_LIMIT))
    os.umask(0o077)


def run(argv, timeout=15, env=None):
    record('$ ' + ' '.join(argv))
    raw = OUT / '.command-output'
    try:
        with raw.open('wb') as stream:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stream,
                                    stderr=subprocess.STDOUT, start_new_session=True,
                                    preexec_fn=child_limits, env=env)
            try:
                rc = proc.wait(timeout)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                rc = 124
        text = raw.read_bytes()[:FILE_LIMIT].decode(errors='replace')
    except OSError as exc:
        rc, text = 127, str(exc)
    finally:
        raw.unlink(missing_ok=True)
    record(f'exit={rc}\n{text}')
    return rc, text


def check(name, argv, pattern=None, timeout=15, env=None):
    rc, text = run(argv, timeout, env)
    good = rc == 0 and (pattern is None or re.search(pattern, text, re.M) is not None)
    require(name, good, '' if good else f'exit={rc}; {text[-400:].strip()}')
    return text if good else None


def info(name, argv, filename=None):
    rc, text = run(argv)
    if filename:
        used = sum(p.stat().st_size for p in OUT.iterdir() if p.is_file())
        if used < BUNDLE_LIMIT - FILE_LIMIT:
            (OUT / filename).write_text(redact(text)[:FILE_LIMIT], encoding='utf-8')
    result('INFO', name, f'exit={rc}' if rc else '')
    return text


def read(path):
    try:
        return Path(path).read_text(errors='replace').strip().strip('\0')
    except OSError:
        return ''


def find_net_phy(interface):
    net = Path('/sys/class/net', interface)
    for path in (net / 'phydev', net / 'device/phydev'):
        if path.exists():
            return path.resolve()
    try:
        handle = (net / 'device/of_node/phy-handle').read_bytes()
    except OSError:
        handle = b''
    for phy in Path('/sys/bus/mdio_bus/devices').glob('*'):
        attached = phy / 'attached_dev'
        if attached.exists() and attached.resolve() == net.resolve():
            return phy
        for name in ('phandle', 'linux,phandle'):
            try:
                if len(handle) == 4 and (phy / 'of_node' / name).read_bytes() == handle:
                    return phy
            except OSError:
                pass
    return None


def prop(service, path, interface, key):
    return run(['busctl', 'get-property', service, path, interface, key])


def unit(name):
    if check('unit ' + name, ['systemctl', 'is-active', name], '^active$') is None:
        info(name + ' diagnostics', ['journalctl', '-b', '-u', name, '--no-pager', '-n', '20'])


CLIENT = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
AUTH = 'Basic ' + base64.b64encode(('root:' + PASSWORD).encode()).decode()


class CaptureLimitError(ValueError):
    """A diagnostic capture limit is not evidence of a server failure."""


def fetch(path, method='GET', body=None, query=None):
    if not path.startswith('/redfish/v1/') or '..' in path or '?' in path:
        raise ValueError('Invalid local Redfish link: ' + path)
    if query is not None:
        # Only locally generated bounded pagination parameters are accepted.
        # Do not follow arbitrary URLs supplied in @odata.nextLink.
        if (method != 'GET' or set(query) != {'$top', '$skip'}
                or any(type(value) is not int for value in query.values())
                or not 1 <= query['$top'] <= POST_PAGE_SIZE
                or not 0 <= query['$skip'] < POST_ENTRY_LIMIT):
            raise ValueError('Invalid Redfish pagination parameters')
        path += '?' + urllib.parse.urlencode(query)
    req = urllib.request.Request('https://127.0.0.1' + path, method=method,
        headers={'Authorization': AUTH, 'Content-Type': 'application/json', 'Cache-Control': 'no-cache'},
        data=None if body is None else json.dumps(body).encode())
    with CLIENT.open(req, timeout=8) as response:
        raw = response.read(FILE_LIMIT + 1)
        if len(raw) > FILE_LIMIT:
            raise CaptureLimitError(f'HTTP {response.status}; response exceeds 256 KiB capture limit')
        return response.status, json.loads(raw) if raw else {}


def api(name, path):
    try:
        status, data = fetch(path)
        record(f'GET {path} HTTP {status}\n' + json.dumps(data, ensure_ascii=False))
        if not isinstance(data, dict) or 'error' in data:
            raise ValueError('Redfish error/non-object response')
        result('PASS', name, f'HTTP {status}')
        return data
    except CaptureLimitError as exc:
        result('SKIP', name, str(exc) + '; response schema not checked')
        return None
    except (OSError, ValueError, urllib.error.URLError) as exc:
        result('FAIL', name, exc)
        return None


def post_code_entries():
    path = '/redfish/v1/Systems/system/LogServices/PostCodes/Entries'
    name = 'Redfish POST code entries'
    skip = 0
    initial_total = None
    while skip < POST_ENTRY_LIMIT:
        try:
            status, data = fetch(path, query={'$top': POST_PAGE_SIZE, '$skip': skip})
            record(f'GET {path} $top={POST_PAGE_SIZE} $skip={skip} HTTP {status}\n'
                   + json.dumps(data, ensure_ascii=False))
            if not isinstance(data, dict) or 'error' in data:
                raise ValueError('Redfish error/non-object response')
            rows = data.get('Members')
            total = data.get('Members@odata.count')
            if (not isinstance(rows, list) or type(total) is not int or total < 0
                    or len(rows) > POST_PAGE_SIZE):
                raise ValueError('Invalid paginated POST collection schema')
            if any(not isinstance(row, dict)
                   or not isinstance(row.get('@odata.id'), str)
                   or not isinstance(row.get('Message'), str)
                   or not isinstance(row.get('Created'), str) for row in rows):
                raise ValueError('Invalid POST entry schema')
            if initial_total is None:
                initial_total = total
            elif total != initial_total:
                result('PASS', name + ' paginated interface', f'HTTP {status}; {skip} entries checked')
                result('SKIP', name + ' complete snapshot', 'POST count changed while reading; rerun after BIOS POST completes')
                return
            expected = min(POST_PAGE_SIZE, max(0, total - skip))
            if len(rows) != expected:
                raise ValueError(f'POST page has {len(rows)} entries, expected {expected}')
            skip += len(rows)
            if skip >= total:
                result('PASS', name, f'HTTP {status}; {skip} entries checked in bounded pages')
                return
        except CaptureLimitError as exc:
            result('SKIP', name, str(exc) + '; page too large to validate')
            return
        except (OSError, ValueError, urllib.error.URLError) as exc:
            result('FAIL', name + f' at offset {skip}', exc)
            return
    result('PASS', name + ' paginated interface', f'{skip} entries checked')
    result('SKIP', name + ' remaining entries', f'capture limited to {POST_ENTRY_LIMIT} entries')


def members(name, path, limit=32):
    data = api(name, path)
    if data is None:
        return []
    rows = data.get('Members')
    require(name + ' collection schema', isinstance(rows, list))
    if not isinstance(rows, list):
        return []
    if len(rows) > limit or data.get('Members@odata.nextLink'):
        result('SKIP', name + ' remaining members', f'capture limited to first {limit}')
    return [row['@odata.id'] for row in rows[:limit]
            if isinstance(row, dict) and isinstance(row.get('@odata.id'), str)]


def system():
    global HOST
    section('1. System, services, reset reason')
    info('image/kernel', ['sh', '-c', 'cat /etc/os-release; uname -a; cat /proc/cmdline'])
    require('CEB-GNRD device tree', 'CEB-GNRD' in read('/proc/device-tree/model'))
    check('no failed units', ['systemctl', '--failed', '--no-legend', '--no-pager'], r'\A\s*\Z')
    for name in ('bmcweb', 'phosphor-ipmi-host', 'phosphor-ipmi-net@eth0',
        'xyz.openbmc_project.EntityManager', 'xyz.openbmc_project.FruDevice',
        'xyz.openbmc_project.adcsensor', 'xyz.openbmc_project.fansensor',
        'xyz.openbmc_project.hwmontempsensor', 'xyz.openbmc_project.psusensor',
        'phosphor-pid-control', 'ceb-gnrd-fan-settings',
        'ceb-gnrd-fan-owner', 'ceb-gnrd-temp-max', 'ceb-gnrd-alert-led', 'ceb-gnrd-rtc-sync',
        'ceb-gnrd-ncsi', 'ceb-gnrd-boot-progress', 'ceb-gnrd-psu-detect', 'xyz.openbmc_project.Logging.IPMI',
        'rsyslog', 'phosphor-ledcontroller', 'xyz.openbmc_project.LED.GroupManager', 'phosphor-watchdog',
        'xyz.openbmc_project.intrusionsensor', 'ceb-gnrd-sel-logrotate.timer'):
        unit(name)
    rc, state = prop('xyz.openbmc_project.State.BMC', '/xyz/openbmc_project/state/bmc0',
                     'xyz.openbmc_project.State.BMC', 'CurrentBMCState')
    require('BMC Ready', rc == 0 and state.rstrip().endswith('Ready"'))
    rc, state = prop('xyz.openbmc_project.State.Chassis', '/xyz/openbmc_project/state/chassis0',
                     'xyz.openbmc_project.State.Chassis', 'CurrentPowerState')
    HOST = 'on' if rc == 0 and 'PowerState.On' in state else 'off' if rc == 0 and 'PowerState.Off' in state else None
    require('chassis power state readable', HOST is not None, HOST or 'unknown')
    reason = read('/sys/firmware/devicetree/base/chosen/aspeed,boot-reason')
    require('boot reason classified', reason in ('power-on', 'warm'), reason or 'missing')
    try:
        reset_flags = []
        for name in ('aspeed,reset-log', 'aspeed,reset-log3'):
            raw = Path('/sys/firmware/devicetree/base/chosen', name).read_bytes()
            if len(raw) != 4:
                raise ValueError(f'{name}: expected 4 bytes, got {len(raw)}')
            reset_flags.append(int.from_bytes(raw, 'big'))
        reset, reset3 = reset_flags
        # PCI reset bits 4/5 are peripheral events, not BMC warm resets.
        warm = bool((reset & 0xffff004e) or (reset3 & 0xffff))
        expected = 'warm' if warm else 'power-on' if reset & 1 else 'unknown'
        require('boot reason matches reset flags', reason == expected,
                f'SCU064=0x{reset:08x}; SCU06C=0x{reset3:08x}; '
                f'expected={expected}; actual={reason or "missing"}')
    except (OSError, ValueError) as exc:
        result('FAIL', 'boot reset flags readable', exc)
    info('reset flags/restore decision', ['sh', '-c',
        'for f in /sys/firmware/devicetree/base/chosen/aspeed,reset-log*; do echo "$f"; od -x "$f"; done; '
        'journalctl -b -u xyz.openbmc_project.Chassis.Control.Power@0 --no-pager -n 60'])
    check('restore policy readable', ['ipmitool', 'chassis', 'policy', 'list'],
          'always-off|always-on|previous|no-change')
    result('SKIP', 'AC/warm reset policy behavior', 'needs separate AC and software/watchdog reset runs')
    info('watchdog/restart counters', ['systemctl', 'show', 'bmcweb', 'ceb-gnrd-temp-max',
         '-p', 'NRestarts', '-p', 'WatchdogUSec', '-p', 'Result', '-p', 'OnFailure'])
    info('time synchronization state', ['timedatectl', 'status'])
    check('systemd hardware watchdog configured', ['systemctl', 'show', '-p', 'RuntimeWatchdogUSec'],
          r'RuntimeWatchdogUSec=(2min|120000000)')
    require('watchdog device exists', Path('/dev/watchdog0').exists() or Path('/dev/watchdog').exists())


def ipmi_sensors_fans():
    section('2. IPMI, sensors, FRU, fans and GPIO')
    check('IPMI Get Device ID', ['ipmitool', 'raw', '0x06', '0x01'], r'^\s*[0-9a-f]{2} ')
    check('IPMI identity', ['ipmitool', 'mc', 'info'], r'Manufacturer ID\s*:\s*6659')
    check('chassis status', ['ipmitool', 'chassis', 'status'], 'System Power')
    check('SEL information', ['ipmitool', 'sel', 'info'], 'Version')
    check('SOL configuration', ['ipmitool', 'sol', 'info', '1'], 'Enabled')
    check('IPMI host watchdog readable', ['ipmitool', 'mc', 'watchdog', 'get'], 'Watchdog Timer')
    info('LAN/users', ['sh', '-c', 'ipmitool lan print 1; ipmitool user list 1'])
    rc, addr = run(['ip', '-4', '-o', 'addr', 'show', 'eth0'])
    match = re.search(r'\binet (\d+\.\d+\.\d+\.\d+)/', addr)
    if rc == 0 and match:
        # -E keeps the password out of command lines and the captured report.
        lan_env = dict(os.environ, IPMI_PASSWORD=PASSWORD)
        check('IPMI LAN+ authentication/Get Device ID', ['ipmitool', '-I', 'lanplus', '-H', match[1],
              '-U', 'root', '-E', '-N', '2', '-R', '1', 'mc', 'info'],
              r'Manufacturer ID\s*:\s*6659', timeout=20, env=lan_env)
    else:
        result('SKIP', 'IPMI LAN+ authentication', 'eth0 has no IPv4 address')
    text = check('sensor list', ['ipmitool', 'sensor'], r'\|', timeout=40)
    if text:
        # Match the installed configuration rather than a frozen subset of rails.
        config_path = '/usr/share/entity-manager/configurations/ceb-gnrd.json'
        config = json.loads(read(config_path) or '{}').get('Exposes', [])
        require('board sensor configuration readable', bool(config))
        expected = {'CPU_MAX_TEMP': True, 'DIMM_MAX_TEMP': True}
        for item in config:
            kind = item.get('Type')
            name = item.get('Name')
            if kind in ('ADC', 'LM75A', 'AspeedFan') and name:
                expected[name] = item.get('PowerState') == 'ChassisOn'
            elif kind in ('pmbus', 'MEGCRPS800'):
                dev = Path(f'/sys/bus/i2c/devices/{item["Bus"]}-{int(item["Address"], 0):04x}')
                if not (dev / 'driver').exists():
                    result('FAIL' if dev.exists() else 'SKIP', name + ' PMBus sensors',
                           'PSU device exists but driver unbound' if dev.exists() else 'PSU absent; see PSU detection log')
                    continue
                for key, label in item.items():
                    if key.endswith('_Name'):
                        expected[label] = False
        expected.update({'SYS_FAN' + str(i): False for i in range(6)})
        for name, needs_host in expected.items():
            # IPMI SDR names are limited to 16 characters (e.g. PSU voltages).
            rows = [line for line in text.splitlines() if line.split('|')[0].strip() == name[:16]]
            require('sensor ' + name + ' exists', len(rows) == 1)
            if not rows:
                continue
            if needs_host and HOST != 'on':
                result('SKIP', name + ' live value', 'host off/unknown')
                continue
            try:
                good = math.isfinite(float(rows[0].split('|')[1].strip()))
            except (ValueError, IndexError):
                good = False
            require(name + ' live value', good, rows[0].strip())
        bat = [row for row in text.splitlines() if re.search(r'D3V0[ _]BAT0', row)]
        require('D3V0 BAT0 sensor exists', len(bat) == 1)
        if bat:
            fields = bat[0].split('|')
            require('D3V0 BAT0 alarm thresholds absent', len(fields) >= 10
                    and all(x.strip().lower() == 'na' for x in fields[4:10]), bat[0].strip())
    for name, value in (('CPU_MAX_TEMP', 105), ('DIMM_MAX_TEMP', 95)):
        check(name + ' nonrecoverable threshold', ['ipmitool', 'sensor', 'get', name],
              rf'Upper Non-Recoverable\s*:\s*{value}')
    fru = check('FRU 0 readable', ['ipmitool', 'fru', 'print', '0'], 'Board Part Number')
    if fru:
        require('FRU checksums OK', len(re.findall(r'Checksum\s*:\s*OK', fru)) >= 3
                and re.search(r'Checksum\s*:\s*Bad', fru) is None)
        require('FRU board identity populated', re.search(r'Board Product\s*:\s*\S+', fru)
                and re.search(r'Board Serial\s*:\s*\S+', fru) and 'Unknown' not in fru)
    result('SKIP', 'FRU write/restart persistence', 'existing FRU preserved; needs controlled write + restart')
    check('fan OEM Get returns 25 bytes', ['ipmitool', 'raw', '0x30', '0x01'],
          r'^\s*(?:[0-9a-f]{2}\s+){24}[0-9a-f]{2}\s*$')
    check('fan control zone exists', ['busctl', '--list', 'tree', 'xyz.openbmc_project.State.FanCtrl'],
          r'/xyz/openbmc_project/settings/fanctrl/zone\d+')
    lines = info('GPIO names/directions/ownership', ['gpioinfo'], 'gpio.log')
    for name in ('BMC_CPU_POWER_BUTTON', 'BMC_CPU_RESET', 'BMC_CPU_PWRGD', 'BMC_BIOS_BOOT_OK',
        'BMC_POWER_BUTTON_INPUT', 'BMC_UID_BUTTON_N', 'BMC_UID_LED', 'BMC_SYS_ALERT_LED',
        'BMC_HBLED_N', 'BMC_FAN_BMC_OVERRIDE_N', 'BMC_BIOS_FLASH_SELECT', 'BMC_FRU_WP'):
        require('GPIO ' + name + ' named', '"' + name + '"' in lines)
    owner = [line for line in lines.splitlines() if 'BMC_FAN_BMC_OVERRIDE_N' in line]
    require('fan mux requested as output', bool(owner) and 'output' in owner[0] and 'unused' not in owner[0])
    rc, data = run(['devmem', '0x1e780070', '32'])
    try:
        require('GPIOI6 high (BMC fan ownership)', rc == 0 and bool(int(data.strip(), 0) & (1 << 6)))
    except ValueError:
        result('FAIL', 'fan mux GPIO level readable', data.strip())
    rc, data = run(['devmem', '0x1e7800ac', '32'])
    try:
        require('fan ownership reset tolerance cleared', rc == 0 and not (int(data.strip(), 0) & (1 << 6)))
    except ValueError:
        result('FAIL', 'fan ownership reset tolerance readable', data.strip())
    hwmons = list(Path('/sys/class/hwmon').glob('hwmon*'))
    for n in range(1, 7):
        tach = [h / f'fan{n}_input' for h in hwmons if (h / f'fan{n}_input').exists()]
        pwm = [h / f'pwm{n}' for h in hwmons if (h / f'pwm{n}').exists()]
        pwm += [h / 'pwm1' for h in hwmons if (h / 'pwm1').exists()
                and (h / 'device').resolve().name == f'pwm-fan{n-1}']
        require(f'fan{n} PWM/TACH available', bool(tach and pwm))
        record(', '.join(f'{p}={read(p)}' for p in tach + pwm))
    for name in ('fault', 'identify', 'bmc-heartbeat'):
        require(name + ' LED exists', Path('/sys/class/leds', name).exists())
    require('heartbeat trigger selected', '[heartbeat]' in read('/sys/class/leds/bmc-heartbeat/trigger'))
    rc, value = prop('xyz.openbmc_project.LED.GroupManager', '/xyz/openbmc_project/led/groups/enclosure_fault',
                     'xyz.openbmc_project.Led.Group', 'Asserted')
    require('fault LED group readable', rc == 0 and value.strip() in ('b true', 'b false'))
    require('intrusion latch exposed', bool(list(Path('/sys/class/hwmon').glob('hwmon*/intrusion0_alarm'))))
    for dev in ('6-0048', '6-0049', '6-004a', '6-004b', '9-006f', '10-0050'):
        path = Path('/sys/bus/i2c/devices', dev)
        require('I2C ' + dev + ' driver bound', (path / 'driver').exists(), read(path / 'name'))
    info('PSU presence/probe log', ['journalctl', '-b', '-u', 'ceb-gnrd-psu-detect', '--no-pager', '-n', '40'])
    info('PSU PMBus/hwmon inputs', ['sh', '-c',
         'for h in /sys/class/hwmon/hwmon*; do echo "$h $(cat "$h/name")"; '
         'for f in "$h"/in*_label "$h"/power*_label "$h"/temp*_label; do '
         '[ -f "$f" ] && echo "$f=$(cat "$f")"; done; done'])
    if HOST == 'on':
        cpu_devices = [p for p in Path('/sys/bus/peci/devices').glob('*')
                       if re.fullmatch(r'\d+-[0-9a-fA-F]{2}', p.name)]
        require('PECI CPU devices enumerated', bool(cpu_devices), ', '.join(p.name for p in cpu_devices))
        for path in cpu_devices:
            require('PECI CPU driver bound ' + path.name, (path / 'driver').exists(), read(path / 'uevent'))
        for prefix in ('peci_cputemp', 'peci_dimmtemp'):
            inputs = [p for h in hwmons if read(h / 'name').startswith(prefix)
                      for p in h.glob('temp*_input')]
            readable = []
            for path in inputs:
                value = read(path)
                record(f'{path}={value}')
                if re.fullmatch(r'-?\d+', value):
                    readable.append(path)
            require(prefix + ' live temperature source', bool(readable),
                    'aggregate CPU/DIMM values can be failsafe defaults; require a readable PECI source')
    else:
        result('SKIP', 'PECI live enumeration', 'host off/unknown')


def memory_ecc():
    section('BMC DDR ECC')
    if ENV == 'qemu':
        result('SKIP', 'physical DDR ECC', 'QEMU does not validate physical DDR correction')
        return
    registers = {}
    for name, address in (('config', '0x1e6e0004'), ('range', '0x1e6e0054')):
        rc, text = run(['devmem', address, '32'])
        try:
            if rc != 0:
                raise ValueError(text.strip())
            registers[name] = int(text.strip(), 0)
        except ValueError:
            result('FAIL', 'ECC ' + name + ' register readable', text.strip())
            return
    enabled = bool(registers['config'] & (1 << 7))
    require('BMC DDR ECC enabled', enabled, f"MCR04=0x{registers['config']:08x}")
    if enabled:
        protected = (registers['range'] & 0x7ff00000) + (1 << 20)
        try:
            reg = Path('/sys/firmware/devicetree/base/memory@80000000/reg').read_bytes()
            if len(reg) != 8:
                raise ValueError('expected one 32-bit address/size pair')
            base, size = int.from_bytes(reg[:4], 'big'), int.from_bytes(reg[4:], 'big')
            require('Linux RAM inside ECC data range',
                    base == 0x80000000 and 0 < size <= protected,
                    f'RAM={size >> 20} MiB, protected={protected >> 20} MiB')
        except (OSError, ValueError) as exc:
            result('FAIL', 'ECC Linux memory range readable', str(exc))
    controller = Path('/sys/devices/system/edac/mc/mc0')
    require('ASPEED EDAC memory controller registered', controller.is_dir())
    for counter in ('ce_count', 'ue_count'):
        value = read(controller / counter)
        require('EDAC ' + counter + ' readable', value.isdecimal(), value)
        if counter == 'ue_count' and value.isdecimal():
            require('no uncorrectable DDR ECC errors', int(value) == 0, value)


def peripherals_network():
    section('3. eSPI/KCS/POST/SOL, RTC, USB/VGA and network')
    for node in ('/dev/ipmi-kcs3', '/dev/aspeed-lpc-snoop0', '/dev/ttyS2', '/dev/ttyVUART0', '/dev/rtc0', '/dev/video0', '/dev/nbd0'):
        require(node + ' exists', Path(node).exists())
    unit('obmc-console@ttyS2')
    unit('obmc-console@ttyVUART0')
    unit('phosphor-ipmi-kcs@ipmi-kcs3')
    check('SOL physical tty configuration', ['stty', '-F', '/dev/ttyS2', '-a'], 'speed|baud')
    check('SOL vUART tty configuration', ['stty', '-F', '/dev/ttyVUART0', '-a'], 'speed|baud')
    require('SOL socket registered', 'obmc-console' in read('/proc/net/unix'))
    base = '/sys/devices/platform/ahb/ahb:apb/1e787000.serial/'
    require('SOL vUART COM1 address', re.fullmatch(r'0x0*3[fF]8', read(base + 'lpc_address')) is not None)
    require('SOL SerIRQ 4', read(base + 'sirq') == '4')
    for addr, mask in (('0x1e6ee000', 0x0f00000a), ('0x1e6ee098', 0x00900000)):
        rc, value = run(['devmem', addr, '32'])
        try:
            require('eSPI ready ' + addr, rc == 0 and int(value.strip(), 0) & mask == mask, value.strip())
        except ValueError:
            result('FAIL', 'eSPI register readable ' + addr, value.strip())
    rc, value = prop('xyz.openbmc_project.State.Boot.PostCode0', '/xyz/openbmc_project/State/Boot/PostCode0',
                     'xyz.openbmc_project.State.Boot.PostCode', 'CurrentBootCycleCount')
    match = re.search(r'\b[qut] (\d+)', value)
    require('POST history retained cycles <= 2', rc == 0 and match is not None and int(match[1]) <= 2, value.strip())
    slots = [p for p in Path('/var/lib/phosphor-post-code-manager/host0').glob('*') if p.name.isdecimal()]
    require('POST persisted archive slots <= 2', len(slots) <= 2, ', '.join(p.name for p in slots))
    if HOST == 'on':
        require('POST history nonempty', match is not None and int(match[1]) > 0)
    check('RTC time readable', ['hwclock', '-r'], r'\d')
    info('RTC voltage-loss status', ['hwclock', '--vl-read'])
    udcs = list(Path('/sys/class/udc').glob('*'))
    require('vHub UDCs available', len(udcs) >= 2, f'count={len(udcs)}')
    hid = Path('/sys/kernel/config/usb_gadget/obmc_hid')
    require('HID gadget configured', hid.is_dir() and bool(list((hid / 'functions').glob('hid.*'))))
    hid_udc = read(hid / 'UDC')
    if hid_udc:
        require('HID gadget bound to available UDC', Path('/sys/class/udc', hid_udc).exists(), hid_udc)
    else:
        result('SKIP', 'HID gadget binding', 'HID binds during an active KVM session; open KVM to check input end-to-end')
    for g in Path('/sys/kernel/config/usb_gadget').glob('*'):
        record(f'gadget={g.name} UDC={read(g / "UDC")}')
    record('UDC state: ' + ', '.join(f'{u.name}={read(u / "state")}' for u in udcs))
    media = Path('/sys/kernel/config/usb_gadget/mass-storage')
    if media.exists():
        backing = read(media / 'functions/mass_storage.usb0/lun.0/file')
        sectors = read('/sys/block/' + Path(backing).name + '/size') if backing.startswith('/dev/nbd') else ''
        require('mounted media bound to UDC', bool(read(media / 'UDC')))
        require('mounted media capacity > 0', sectors.isdecimal() and int(sectors) > 0,
                f'backing={backing}; sectors={sectors or "unknown"}')
        pid = read('/sys/block/' + Path(backing).name + '/pid')
        require('mounted media NBD client alive', pid.isdecimal() and Path('/proc', pid).exists())
        require('mounted media is read-only', read(media / 'functions/mass_storage.usb0/lun.0/ro') == '1')
    else:
        result('SKIP', 'mounted virtual media', 'no active browser media session; idle NBD size=0 is normal')
    info('NBD/gadget state', ['sh', '-c',
         'for n in /sys/block/nbd*; do echo "$n size=$(cat "$n/size") pid=$(cat "$n/pid" 2>/dev/null)"; done; '
         'for g in /sys/kernel/config/usb_gadget/*; do echo "$g"; cat "$g/UDC"; '
         'for f in "$g"/functions/*/lun.0/file "$g"/functions/*/lun.0/ro; do '
         '[ -f "$f" ] && echo "$f=$(cat "$f")"; done; done'], 'usb-nbd.log')
    info('network addresses', ['ip', '-br', 'addr'], 'network.log')
    check('eth0 IPv4', ['ip', '-4', '-o', 'addr', 'show', 'eth0'], r'inet \d')
    phy = find_net_phy('eth0')
    require('RTL8211 PHY attached', phy is not None, str(phy or 'no PHY associated with eth0 found'))
    require('RTL8211FS PHY identity', phy is not None and read(phy / 'phy_id').lower() == '0x001cc916',
            read(phy / 'phy_id') if phy else 'unavailable')
    require('eth0 carrier', read('/sys/class/net/eth0/carrier') == '1')
    info('RTL8211 PHY registers/identity', ['sh', '-c',
         'for p in /sys/bus/mdio_bus/devices/*; do echo "$p"; cat "$p/phy_id" "$p/uevent"; '
         'readlink -f "$p/attached_dev"; done; '
         'cat /sys/class/net/eth0/speed /sys/class/net/eth0/duplex'])
    require('NC-SI eth1 exists', Path('/sys/class/net/eth1').exists())
    if HOST == 'on':
        require('host-on NC-SI carrier', read('/sys/class/net/eth1/carrier') == '1')
    elif HOST == 'off':
        try:
            require('host-off NC-SI administratively down', not (int(read('/sys/class/net/eth1/flags'), 0) & 1))
        except ValueError:
            result('FAIL', 'NC-SI flags readable')
    for port, table in ((22, 'tcp'), (443, 'tcp'), (623, 'udp')):
        rows = read('/proc/net/' + table) + '\n' + read('/proc/net/' + table + '6')
        state = '0A' if table == 'tcp' else '07'
        require(f'listener {port}/{table}', re.search(rf':{port:04X}\s+\S+\s+{state}', rows) is not None)
    info('NC-SI transition log', ['journalctl', '-b', '-u', 'ceb-gnrd-ncsi', '--no-pager', '-n', '60'])
    result('SKIP', 'PHY/NC-SI link injection and failover', 'requires network panel stimuli')
    result('SKIP', 'USB HID/SOL/KVM/media end-to-end', 'requires browser session + simulator received reports/text/media sector check')


def redfish():
    section('4. Redfish/web interfaces')
    for path in ('', 'Systems/system', 'Managers/bmc', 'AccountService', 'SessionService', 'UpdateService',
        'Systems/system/LogServices/EventLog/Entries',
        'Managers/bmc/LogServices/Dump/Entries'):
        data = api('Redfish ' + (path or 'root'), '/redfish/v1/' + path)
        if path == 'Managers/bmc' and data:
            require('BMC firmware version populated', bool(data.get('FirmwareVersion')))
        if path == 'Systems/system' and data:
            require('Redfish/IPMI chassis state agrees', HOST is not None
                    and data.get('PowerState') == ('On' if HOST == 'on' else 'Off'), data.get('PowerState'))
    post_code_entries()
    for name, path in (('EthernetInterfaces', '/redfish/v1/Managers/bmc/EthernetInterfaces'),
                       ('Accounts', '/redfish/v1/AccountService/Accounts'),
                       ('FirmwareInventory', '/redfish/v1/UpdateService/FirmwareInventory')):
        for link in members(name, path):
            api(name + ' ' + link.rsplit('/', 1)[-1], link)
    for chassis in members('Chassis', '/redfish/v1/Chassis'):
        data = api('Chassis resource', chassis)
        if not data:
            continue
        require('PhysicalSecurity exposed', 'PhysicalSecurity' in data)
        for key in ('Sensors', 'Thermal', 'Power', 'ThermalSubsystem', 'PowerSubsystem'):
            link = data.get(key, {}).get('@odata.id') if isinstance(data.get(key), dict) else None
            if link:
                endpoint = api(key + ' ' + chassis, link)
                if key == 'Sensors' and endpoint:
                    rows = endpoint.get('Members', [])
                    if len(rows) > 64 or endpoint.get('Members@odata.nextLink'):
                        result('SKIP', 'remaining Redfish sensors', 'capture limited to 64')
                    for row in rows[:64]:
                        if isinstance(row, dict) and isinstance(row.get('@odata.id'), str):
                            api('sensor ' + row['@odata.id'].rsplit('/', 1)[-1], row['@odata.id'])
        require('chassis thermal/sensor resource exposed', any(key in data for key in ('Sensors', 'Thermal', 'ThermalSubsystem')))
    found = False
    for parent in ('/redfish/v1/Systems/system', '/redfish/v1/Managers/bmc'):
        try:
            _, data = fetch(parent)
            link = data.get('VirtualMedia', {}).get('@odata.id')
        except (OSError, ValueError, urllib.error.URLError):
            link = None
        if link:
            found = True
            for path in members('VirtualMedia', link):
                api('VirtualMedia device', path)
    if not found:
        result('SKIP', 'Redfish VirtualMedia collection', 'browser NBD websocket mode may not expose this resource')
    check('web UI served', ['curl', '--noproxy', '*', '-ksSf', '--max-time', '8', 'https://127.0.0.1/'],
          r'(?i)<html|<!doctype html')
    check('fan settings D-Bus GetFans', ['busctl', 'call', 'com.ctopai.CebGnrd.FanSettings',
          '/xyz/openbmc_project/ceb_gnrd/fan_settings', 'com.ctopai.CebGnrd.FanSettings', 'GetFans'], r'^ay 25 ')
    result('SKIP', 'browser auto-refresh/websocket transfer', 'needs live browser; HTTP metadata is not an end-to-end check')
    if os.environ.get('CEB_CHECK_CLEAR_LOGS') == '1':
        try:
            status, _ = fetch('/redfish/v1/Systems/system/LogServices/EventLog/Actions/LogService.ClearLog', 'POST', {})
            require('explicit EventLog ClearLog', status in (200, 202, 204))
        except (OSError, ValueError, urllib.error.URLError) as exc:
            result('FAIL', 'EventLog ClearLog', exc)
    else:
        result('SKIP', 'delete/ClearLog', 'destructive; CEB_CHECK_CLEAR_LOGS=1 enables ClearLog only')


def storage_logs():
    section('5. Flash/log budgets and evidence')
    info('MTD/mount/free space', ['sh', '-c', 'cat /proc/mtd; mount; df -k / /var /var/log /var/lib /tmp'], 'storage.log')
    require('BMC SPI flash 64 MiB', read('/sys/class/mtd/mtd0/size') == '67108864')
    stat = os.statvfs('/var/lib')
    free = stat.f_bavail * stat.f_frsize
    require('persistent storage >= 1 MiB free', free >= 1024 * 1024, f'{free // 1024} KiB')
    require('persistent journal budget 1 MiB configured',
            'SystemMaxUse=1M' in read('/etc/systemd/journald.conf.d/60-ceb-gnrd-journal-limits.conf'))
    require('core binary storage disabled',
            'Storage=none' in read('/etc/systemd/coredump.conf.d/60-ceb-gnrd-coredump-limits.conf'))
    info('effective journal/core configuration', ['sh', '-c',
         'systemd-analyze cat-config systemd/journald.conf; systemd-analyze cat-config systemd/coredump.conf'])
    info('log/state sizes', ['sh', '-c',
         'du -k -d 2 /var/log /var/lib 2>/dev/null | sort -n | tail -n 30; journalctl --disk-usage'])
    for file, argv in (
        ('journal.log', ['journalctl', '-b', '--no-pager', '-n', '400']),
        ('bmcweb.log', ['journalctl', '-b', '-u', 'bmcweb', '--no-pager', '-n', '120']),
        ('dmesg.log', ['dmesg']), ('sdr.log', ['ipmitool', 'sdr', 'elist']),
        ('sel.log', ['ipmitool', 'sel', 'elist']),
        ('dbus.log', ['busctl', 'list', '--no-pager']),
        ('failed-units.log', ['systemctl', '--failed', '--no-pager'])):
        info(file, argv, file)


print(f'CEB-GNRD check: env={ENV}; read-only unless ClearLog explicitly enabled', flush=True)
for callback in (system, ipmi_sensors_fans, memory_ecc, peripherals_network, redfish, storage_logs):
    try:
        callback()
    except Exception as exc:
        result('FAIL', callback.__name__ + ' interrupted', f'{type(exc).__name__}: {exc}')
section('Summary')
summary = f'env={ENV} host={HOST or "unknown"} ' + ' '.join(f'{k}={COUNT[k]}' for k in ('PASS', 'FAIL', 'SKIP', 'INFO'))
print(summary, flush=True)
with REPORT.open('ab') as stream:
    stream.write((summary + '\nSKIP is not PASS; resets/live input require external stimuli.\n').encode())
print('Report: /tmp/ceb-gnrd-check/report.txt', flush=True)
(OUT / 'results.json').write_text(json.dumps({'environment': ENV, 'host': HOST,
    'counts': dict(COUNT), 'results': RESULTS}, ensure_ascii=False, indent=2), encoding='utf-8')
# Archive after the summary; tar is not subject to the per-command file limit.
try:
    archive = Path('/tmp/ceb-gnrd-check.tar.gz')
    if archive.is_symlink():
        raise OSError('Refusing a symlink at diagnostic archive path')
    proc = subprocess.run(['tar', 'czf', str(archive), '-C', '/tmp', 'ceb-gnrd-check'],
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=20, check=False)
    if proc.returncode:
        result('FAIL', 'diagnostic archive', f'exit={proc.returncode}')
    else:
        print('Bundle: /tmp/ceb-gnrd-check.tar.gz', flush=True)
except (OSError, subprocess.TimeoutExpired) as exc:
    result('FAIL', 'diagnostic archive', exc)
sys.exit(1 if COUNT['FAIL'] else 0)
