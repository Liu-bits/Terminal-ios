# sysinfo - one screen of facts about the sandbox this shell runs in.
echo "Terminal-ios sysinfo"
echo "--------------------"
echo "kernel:   $(uname -s) $(uname -r)"
echo "arch:     $(uname -m)"
echo "cpus:     $(nproc)"
echo "user:     $(whoami)"
echo "cwd:      $(pwd)"
echo "date:     $(date +%F) $(date +%T)"
echo "uptime:   $(uptime)"
echo "packages:"
apt list | head -n 20
