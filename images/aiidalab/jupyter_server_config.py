# JupyterLab/AiiDAlab server config (baked into the image).
# NOTE: list traits break when parsed from CLI args, so they are set here.
import os
import socket

c = get_config()  # noqa: F821  (jupyter config file convention)

c.ServerApp.ip = "0.0.0.0"  # the pod is the security boundary (network policy + token)
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.terminals_enabled = False  # terminals disabled by policy
if os.path.isdir("/home/aiida"):
    c.ServerApp.root_dir = "/home/aiida"

# Fixed token from the runtime dotenv (AIIDA_JUPYTER_TOKEN, via the
# aiidalab-jupyter Secret): read in the config file because
# jupyter_server only consumes JUPYTER_TOKEN_FILE as a trait *default*, which
# can be shadowed by the ServerApp "<generated>" default.
if os.getenv("JUPYTER_TOKEN_FILE"):
    c.ServerApp.token = open(os.environ["JUPYTER_TOKEN_FILE"]).read().strip()

# Hostnames accepted as "local" by the host-header check. The edge tunnel and
# in-cluster clients use the service DNS name; the pod's own names are added
# for direct pod access. Unknown Host headers only come from trusted edge, so
# the check is disabled as well (defense in depth stays with network policy +
# token auth).
c.ServerApp.local_hostnames = [
    "localhost",
    "127.0.0.1",
    socket.gethostname(),
    socket.getfqdn(),
    "aiidalab",
    "aiidalab.aiidalab",
    "aiidalab.aiidalab.svc",
    "aiidalab.aiidalab.svc.cluster.local",
]
c.ServerApp.allow_remote_access = True

# The image ships no AiiDAlab home launcher (labextensions are plotly and
# pygments only), so "/" landed on the plain JupyterLab launcher. Open the
# notebooks folder instead: that is where the agent writes its repro notebooks
# and where a human arriving at the configured public hostname should start.
c.ServerApp.default_url = "/lab/tree/notebooks"
