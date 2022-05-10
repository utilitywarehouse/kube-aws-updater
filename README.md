## Pushing logs to Loki

### Install

```bash
cd /usr/local/bin
curl -O -L "https://github.com/grafana/loki/releases/latest/download/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip
rm promtail-linux-amd64.zip
mv promtail-linux-amd64 promtail
sudo chmod a+x promtail
```


### Usage

To enable pushing logs to loki pass `-l` arg to the script along with the path to a valid promtail config file ie `./kube-merit-updater -c dev-merit -r master -n 3 -l promtail.conf`

This will run promtail as a background process within the context of the script which will gracefully terminate along with the script

This will redirect stdout and stderr via tee which route the output both to console and to a file called `kube-updater.log` in the current directory

Promtail is by default configured to monitor, read and push files in the current directory with a `.log` suffix.

Promtail will by default push the log line to the prod aws loki deployment `https://loki.prod.aws.uw.systems/api/prom/push`,

Promtail will by default track file positions and push progress in `/tmp/positions.yaml`

The log lines will currently be annoted with the following:
- `context` which is the kube context currently being operated on ie `exp-merit-1`
- `host` which is the hostname of the device the script is currently being executed on ie `jake-desktop`