# Pi Network Provisioning Guide

## Demo Flow

The current demo path is:

1. Turn on `iPhone Personal Hotspot`.
2. Boot the Pi. `smartcane-runtime.service` starts automatically.
3. If hotspot credentials are already present, the Pi joins the hotspot immediately.
4. If hotspot credentials are missing, the Pi stays up in BLE provisioning mode instead of exiting.
5. The iPhone app sends hotspot credentials over BLE.
6. The Pi persists those credentials, joins the iPhone hotspot, starts the WebSocket runtime on `:8080`, and advertises BLE diagnostics.
7. The iPhone app reads the Pi hotspot IP from BLE diagnostics and connects to `ws://<pi-ip>:8080/ws`.

There is no Pi AP required for the demo path.

## First Boot Without SSH

Before first boot, place this file on the SD card boot partition:

```json
{
  "hotspotSSID": "Your iPhone Hotspot Name",
  "hotspotPassword": "your-hotspot-password"
}
```

Accepted keys are:

- `hotspotSSID` or `ssid`
- `hotspotPassword` or `password`

Supported locations:

- `/boot/firmware/smartcane-hotspot.json`
- `/boot/smartcane-hotspot.json`

On first runtime start, the Pi copies that file into `/etc/smartcane/hotspot.json` and uses it for future boots.

This boot-partition file is now optional. It is still useful for image preloading, but you can also send the same credentials from the iPhone app over BLE after boot.

## Raspberry Pi OS Cloud-Init

For Raspberry Pi OS images that support `cloud-init`, the default path is now fully offline on first boot.

Generate boot files and the offline boot payload with:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
chmod +x infra/pi-network/generate_cloud_init.sh
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot \
  --repo-on-pi /home/pi/smartcane-pi \
  --hostname smartcane-pi \
  --hotspot-ssid "Your iPhone Hotspot Name" \
  --hotspot-password "your-hotspot-password" \
  --ssh-password "your-ssh-password"
```

That writes:

- `user-data`
- `meta-data`
- `network-config`
- `smartcane/repo.tar.gz`
- `smartcane/python-vendor.tar.gz`

The generated offline cloud-init setup will:

- enable SSH
- allow SSH password authentication
- unpack the repo from the boot partition
- unpack vendored Python dependencies from the boot partition
- install SmartCane OS tool packages only if the Pi already has internet on first boot
- install and enable `smartcane-runtime.service`
- install and enable `smartcane-ota.timer`

It does not `git clone` or `pip install` on first boot anymore.

If you do not pass `--wheelhouse`, the generator builds that Python payload on the machine where you run `generate_cloud_init.sh`.
The generated first-boot script also writes a boot-partition log at `smartcane/firstboot.log`, which is useful if the Pi never becomes reachable over BLE or Wi‑Fi.

If you want later OTA updates from GitHub releases, add the repo URL when generating:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot \
  --repo-url https://github.com/your-org/REDesign.git \
  --repo-branch main
```

That remote is only for later OTA. The first boot remains offline.

The provisioning scripts will derive this OTA manifest URL automatically:

- `https://github.com/<owner>/<repo>/releases/download/pi-latest/smartcane-pi-manifest.json`

Or pass it explicitly:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot \
  --ota-manifest-url https://github.com/your-org/REDesign/releases/download/pi-latest/smartcane-pi-manifest.json
```

If you already have a local wheelhouse, point the generator at it:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot \
  --wheelhouse /path/to/wheelhouse
```

For zero-touch deployment, this is the preferred Raspberry Pi OS path instead of logging in manually on first boot.

If you want the runtime service enabled before the Pi ever boots, stage the mounted SD card image offline:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
chmod +x infra/pi-network/stage_image.sh
infra/pi-network/stage_image.sh \
  --root /path/to/mounted/rootfs \
  --boot /path/to/mounted/boot \
  --repo-on-pi /home/pi/smartcane-pi \
  --hotspot-ssid "Your iPhone Hotspot Name" \
  --hotspot-password "your-hotspot-password"
```

That script writes `smartcane-runtime.service` into the mounted rootfs, enables it for `multi-user.target`, and drops `smartcane-hotspot.json` onto the boot partition.

## Install Once On The Pi Image

If you are preparing the SD image ahead of time on a live Pi, install the service once:

```bash
cd /path/to/smartcane-pi
sudo infra/pi-network/setup.sh
```

That script:

- installs OS packages
- enables Raspberry Pi I2C support for the handle IMU
- creates `runtime/.venv` and Python dependencies
- installs and enables `smartcane-runtime.service`
- enables Bluetooth for BLE diagnostics

After that, normal boots do not require SSH.

## Manual Commands

```bash
# Start runtime manually
sudo runtime/.venv/bin/python runtime/src/main.py

# Install hotspot-client dependencies and write hotspot config from boot/internal storage
sudo runtime/.venv/bin/python runtime/src/main.py --setup-hotspot

# Print hotspot-client status
python3 runtime/src/main.py --status

# View runtime logs
journalctl -u smartcane-runtime -f
tail -f runtime/logs/pi_runtime.log
```

## BLE Provisioning And Diagnostics

The Pi now exposes a BLE GATT provisioning service plus the rotating BLE diagnostics beacon.

From the app debug screen you can:

- enter hotspot SSID and password
- send them to the Pi over BLE
- read detailed Pi status JSON without reprovisioning
- read back Pi provisioning status JSON
- inspect the rotating diagnostics beacon

The diagnostics beacon still displays:

- network mode
- hotspot client active or not
- runtime active or not
- app client connected or not
- runtime IP
- pairing stage
- last error
- recent event history

This is the fallback diagnostics path when the Wi-Fi connection fails and the provisioning path when hotspot credentials are not already present.

The detailed BLE status JSON now also includes:

- configured network list
- current associated SSID
- last connected SSID
- last attempted SSID
- last failure reason
- missing OS packages
- recent Pi debug messages

If OTA breaks the runtime, the updater now rolls back to the previous Pi bundle automatically.

## OTA Updates

SmartCane now includes an artifact-based OTA update path.

Installed components:

- [ota_update.sh](/Users/hanyuxuan/Desktop/REDesign/pi/infra/pi-network/ota_update.sh:1)
- [smartcane-ota.service](/Users/hanyuxuan/Desktop/REDesign/pi/infra/pi-network/systemd/smartcane-ota.service:1)
- [smartcane-ota.timer](/Users/hanyuxuan/Desktop/REDesign/pi/infra/pi-network/systemd/smartcane-ota.timer:1)

Default behavior:

- checks every 30 minutes
- fetches `smartcane-pi-manifest.json`
- downloads `smartcane-pi-bundle.tar.gz`
- verifies the SHA-256 checksum from the manifest
- swaps the deployed `pi/` bundle in place
- refreshes installed `systemd` unit files from the new bundle
- keeps the previous bundle as rollback state until the new runtime passes health check
- restarts `smartcane-runtime.service`

The published bundle contains:

- `runtime/`
- `infra/`
- vendored `runtime/vendor` Python dependencies
- release metadata files

GitHub Actions publishes those assets through:

- [pi-cd.yml](/Users/hanyuxuan/Desktop/REDesign/.github/workflows/pi-cd.yml:1)

Manual trigger:

```bash
sudo systemctl start smartcane-ota.service
```

Inspect status:

```bash
systemctl status smartcane-ota.service smartcane-ota.timer --no-pager
tail -f /var/log/smartcane-ota.log
```

## Legacy AP Test Mode

The old rollback-safe Pi AP flow is still available for debugging only:

```bash
sudo runtime/.venv/bin/python runtime/src/main.py --ap-test 300
```

That is no longer the primary demo networking method.
