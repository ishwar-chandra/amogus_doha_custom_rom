# GCP builder

Creates a 12 vCPU / 48 GB VM, installs the Android 16 build dependencies, and
runs the whole buildkit remotely.

## OS and sizing

| Item | Choice | Why |
|---|---|---|
| OS | **Ubuntu 24.04 LTS** (`ubuntu-2404-lts-amd64`) | current LTS, Python 3.12, glibc 2.39; the repo’s dependency list is tested on 22.04/24.04 |
| Shape | **e2-standard-12** first | exactly 12 vCPU / 48 GB, cheapest 12/48 shape |
| Fallbacks | `t2d-standard-12`, `n2d-standard-12`, `n2-standard-12`, `c2-standard-12` | same 12/48, used when e2 is unavailable in a zone |
| Disk | **500 GB `pd-balanced`** | ~200 GB source + ~120 GB `out/` + 50 GB ccache + 32 GB swap + headroom |
| Swap | 32 GB file | Soong peaks around 20 GB; swap is an OOM safety net |
| Zone | auto | cheapest approximate region order, first zone with an available shape |

The disk type can be changed with `DISK_TYPE=pd-standard` (cheaper/slower) or
`DISK_TYPE=pd-ssd` (faster/more expensive). Use `DISK_SIZE=600GB` if you want
more headroom.

## One-time setup

`gcloud` is already installed and authenticated. Verify:

```bash
gcloud config list
gcloud auth list
```

## Create

```bash
# show the selected zone/shape without creating anything
./gcp/create-vm.sh find

# create the VM + SSH firewall rule
./gcp/create-vm.sh create
```

The script writes `gcp/vm.env` (project, zone, VM name, shape) and ignores it
in git.

If your project has no 12 vCPU quota in the auto-selected region, creation
fails with a quota error. Pick a region that has quota:

```bash
ZONE=us-central1-a ./gcp/create-vm.sh create
```

Or choose a specific shape:

```bash
MACHINE_TYPE=n2-standard-12 ZONE=europe-west1-b ./gcp/create-vm.sh create
```

## Build

```bash
./gcp/build-remote.sh
```

That script:

1. tars the buildkit and copies it to `~/amogus_doha_custom_rom`
2. installs packages and the 32 GB swap file
3. runs `./scripts/build.sh all` inside `tmux`
4. downloads `dist/` to `dist-gcp/` and the log to `dist-gcp-build.log`

The build survives an SSH disconnect because it runs in `tmux`. To reattach:

```bash
./gcp/create-vm.sh ssh
tmux attach -t doha
```

If you re-run `build-remote.sh` while the build is active, use:

```bash
SKIP_SYNC=1 ./gcp/build-remote.sh
```

so the remote source tree is not replaced mid-build.

## Stop / delete

```bash
./gcp/create-vm.sh stop      # disk still billed
./gcp/create-vm.sh start
./gcp/create-vm.sh status
./gcp/create-vm.sh delete    # VM + boot disk
```

Delete the VM when the build is finished; a stopped VM still bills for the
500 GB disk.

## Cost notes

- `e2-standard-12` is the cheapest 12/48 option; `t2d`/`n2d` are close,
  `n2` and `c2` cost more.
- 500 GB `pd-balanced` is a few cents per hour; `pd-standard` is cheaper but
  slower.
- A 3–5 hour build is a few dollars of trial credit; `SPOT=1` cuts the compute
  price substantially but can be preempted. Do not use spot for a first
  unattended build.
- Stop/delete the VM when idle. The boot disk is the main idle cost.

## Notes

- The SSH firewall defaults to `0.0.0.0/0` on port 22 with the
  `doha-builder` target tag. Narrow it with
  `SSH_SOURCE_RANGE=<your-ip>/32 ./gcp/create-vm.sh create`.
- The VM has no service account/scopes; it only needs outbound network.
- GCP’s free-trial quotas vary. If `create` fails with
  `QUOTA_EXCEEDED`, try another zone or reduce `DISK_SIZE`.

If `find` is slow on your network, skip it:

```bash
ZONE=us-central1-a MACHINE_TYPE=e2-standard-12 ./gcp/create-vm.sh create
```

Set `FIND_TIMEOUT=300` to allow a longer machine-type query.
