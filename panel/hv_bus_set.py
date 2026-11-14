"""Set variables on this Brilliant panel's message bus.

    /data/switch-embedded/env/bin/python hv_bus_set.py <peripheral> '<json {name: value}>'
    /data/switch-embedded/env/bin/python hv_bus_set.py '<json {peripheral: {name: value}}>'

Runs under Brilliant's own interpreter because it uses Brilliant's compiled message bus
client. hv_sliders.py calls it to steer Brilliant's screen schedule (night mode).
"""
import asyncio, inspect, json, os, sys

SITE = "/data/switch-embedded/env/lib/python3.10/site-packages"
FLAGFILES = ["/var/run/brilliant/flagfiles/art_flagfile", "/var/brilliant/device-flags"]

os.chdir("/data/switch-embedded")
sys.path.insert(0, SITE)
import gflags  # noqa: E402
import configs.process_configs, configs.switch_gflags  # noqa: E402,F401  (define the flags we parse)
from lib.protocol import processor, message_bus_peer_service as mbps  # noqa: E402
from lib.message_bus_api.observer_interface import RPCObserver  # noqa: E402

defined = [l.split("=")[0][2:] for f in FLAGFILES for l in open(f) if l.startswith("--")]
gflags.FLAGS(["hv_bus_set", "--undefok=" + ",".join(defined)] + [f"--flagfile={f}" for f in FLAGFILES])
ME = gflags.FLAGS.device_id


async def maybe(result):
    return await result if inspect.isawaitable(result) else result


async def main():
    loop = asyncio.get_running_loop()
    observer = RPCObserver(loop)
    proc = processor.SinglePeerProcessor(
        socket_path=gflags.FLAGS.message_bus_server_socket_path, my_name="homeview_bus_set",
        handler=mbps.PeripheralServer(observer), client_class=mbps.MessageBusClient, loop=loop)
    await proc.start()
    await observer.start(proc)
    bundle = {sys.argv[1]: json.loads(sys.argv[2])} if len(sys.argv) > 2 else json.loads(sys.argv[1])
    for peripheral, values in bundle.items():
        r = await maybe(observer.request_set_variables_in_peripheral(peripheral, values, device_id=ME))
        print("set", peripheral, [mv.variable_name for mv in (r.modified_variables or ())], flush=True)


asyncio.run(main())
