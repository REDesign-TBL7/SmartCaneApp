# Pi Bundle

`pi/` is the deployable Raspberry Pi bundle.

It contains only the code and scripts the Pi needs:

```text
pi/
  runtime/ Python runtime, requirements, logs, and Pi-side docs
  infra/   Network provisioning, cloud-init, OTA, and systemd helpers
```

Preferred workflow:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
sudo infra/pi-network/setup.sh
```

For image provisioning, run the same helpers from this directory:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
infra/pi-network/generate_cloud_init.sh --boot /path/to/boot
infra/pi-network/stage_image.sh --root /path/to/rootfs --boot /path/to/boot
```

Notes:

- The monorepo root still exposes `infra/` as a compatibility symlink into `pi/infra`.
- The bundle also exposes `src`, `requirements.txt`, and `logs` symlinks for compatibility, but `runtime/` is the canonical runtime location.
- OTA now consumes the Pi-only release bundle published by `.github/workflows/pi-cd.yml`.
