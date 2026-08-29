# Mooncake UB GDR Deployment Guide

This guide covers building and deploying Mooncake's UB transport with GPU Direct
RDMA (GDR) support, and benchmarking cross-node GDR + remote-SSD data transfer
using `stress_cluster_bench`.

## 1. Test Object & Architecture

### Test objective

Measure cross-node GDR transfer from a remote SSD to GPU HBM:

- A **writer** process on the SSD node prefills data and offloads it to local
  SSD via eviction.
- A **reader** process on the GPU node pulls SSD data through the GDR link and
  lands it directly into GPU HBM (gdr-peermem) or via a host staging buffer
  (staging).

### Deployment topology (remote_disk scenario only)

```
              Control plane (no KV data)
        +-------------------------------+
        | mooncake_master               |
        |  gRPC :50051  HTTP :8080      |
        |  metrics :9003                |
        +---------------+---------------+
                        |
        +---------------+---------------+
        | DATA PLANE                      |
        |                                |
  writer (SSD node)               reader (GPU node)
  role=writer                     role=reader
  gpu_mode = host (fixed)         gpu_mode = gdr-peermem | staging
  enable_ssd_offload=true         gpu_device=N
  global_segment_size (small)     --
        |                                |
        +-- SSD (offloaded via evict) --+
                                         |
                        reader pulls SSD -> GDR -> GPU HBM
```

### GDR + SSD datastream (default: pull mode, `MC_OFFLOAD_PUSH` unset)

```
reader get_into(gpu_buffer)
  -> RealClient execute_ranged_read (LOCAL_DISK replica)
  -> batch_get_into_offload_object_internal
  -> RPC batch_get_offload_object (keys+sizes only) ----> writer
  writer: file_storage->BatchGet (SSD -> writer DDR)
  <---- returns pointers + transfer_engine_addr ----
  reader: submit_batch_get_offload_object
     TransferRequest::READ, source = reader GPU buffer
     -> UbTransport::submitTransferTask
         gdr-peermem : NIC directly DMA GPU HBM (is_gpu_seg=1)
         staging     : NIC DMA host staging buffer -> cudaMemcpy H2D
```

Push mode (`export MC_OFFLOAD_PUSH=true`) reverses the final leg: the writer
issues `urma_write` into the reader's VA instead of the reader issuing
`urma_read`.

## 2. Prerequisites

- **UMDK headers** with `urma_seg_cfg_t::is_gpu_seg` field (e.g. the
  `UMDK_tool_netlab` source tree). The build probes this field and aborts
  (FATAL_ERROR) if missing.
- **liburma.so** — provide the exact path via `-DURMA_LIBRARY`, or let CMake
  `find_library` search `/usr/lib64 /usr/local/lib64 /usr/lib`. If none is
  found, a mock URMA backend is built (GDR unsupported).
- **CUDA toolkit** — required for `USE_CUDA` builds (`cuMemAlloc`,
  `cuPointerSetAttribute`, `cudaMemcpy`).
- **GPU peermem path** — either the `nvidia_peermem` kernel module, or your
  custom kernel module that accesses `nvidia.ko` symbols, loaded on the GPU
  node.
- **libnuma** — for host buffer allocation.

## 3. Compilation

### Configure

```bash
cmake -B build \
  -DUSE_UB=ON \
  -DUSE_CUDA=ON \
  -DURMA_ROOT=/path/to/umdk/src/urma/lib/urma \
  -DURMA_LIBRARY=/path/to/liburma.so \
  -DBUILD_BENCHMARK=ON \
  -DBUILD_UNIT_TESTS=OFF
```

- `URMA_ROOT` points at the URMA lib directory containing `core/include/` and
  `bond/include/`. Empty falls back to FetchContent from atomgit.
- `URMA_LIBRARY` pins `liburma.so`; empty falls back to `find_library`.
- The configure step runs `check_cxx_source_compiles` on `is_gpu_seg` and fails
  hard if the UMDK headers lack it.

### Build targets

```bash
make -C build -j stress_cluster_bench mooncake_master
```

- `stress_cluster_bench` — the GDR benchmark (reader/writer).
- `mooncake_master` — control-plane coordinator + metadata service.

Artifacts land under `build/mooncake-store/benchmarks/` and
`build/mooncake-store/src/`.

## 4. Deployment Sequence

Start in order: master -> writer -> reader. The writer must finish prefill +
offload before the reader starts.

### Step 1 — master (any node)

```bash
mooncake_master \
  --rpc_address=0.0.0.0 \
  --port=50051 \
  --metrics_port=9003 \
  --enable_http_metadata_server=true \
  --http_metadata_server_host=0.0.0.0 \
  --http_metadata_server_port=8080 \
  --enable_offload=true \
  --offload_on_evict=true \
  --eviction_high_watermark_ratio=0.80 \
  --logtostderr=true
```

### Step 2 — writer (SSD node)

```bash
stress_cluster_bench \
  --scenario=remote_disk \
  --role=writer \
  --protocol=ub \
  --device_name=bonding_dev_0 \
  --local_hostname=<SSD_NODE_IP>:12345 \
  --metadata_server=http://<MASTER_IP>:8080/metadata \
  --master_server=<MASTER_IP>:50051 \
  --global_segment_size=1073741824 \
  --local_buffer_size=536870912 \
  --value_size=4194304 \
  --num_keys=2000 \
  --batch_size=1 \
  --replica_num=1 \
  --enable_ssd_offload=true \
  --ssd_offload_path=/mnt/ssd \
  --wait_seconds=120 \
  --logtostderr=true
```

- `global_segment_size` must be small enough that
  `num_keys * value_size > 0.90 * global_segment_size`, so eviction offloads
  data to SSD.
- Writer uses host buffers only (`--gpu_mode` must be empty/`host`).

### Step 3 — reader (GPU node, after writer finished)

```bash
stress_cluster_bench \
  --scenario=remote_disk \
  --role=reader \
  --protocol=ub \
  --device_name=bonding_dev_0 \
  --gpu_mode=gdr-peermem \
  --gpu_device=0 \
  --local_hostname=<GPU_NODE_IP>:12346 \
  --metadata_server=http://<MASTER_IP>:8080/metadata \
  --master_server=<MASTER_IP>:50051 \
  --global_segment_size=33554432 \
  --value_size=4194304 \
  --num_keys=2000 \
  --batch_size=1 \
  --num_threads=4 \
  --wait_seconds=120 \
  --verify=true \
  --logtostderr=true
```

For the staging path instead of gdr-peermem, set `--gpu_mode=staging`.

## 5. Parameter Reference

### Common flags

| Flag | Meaning |
|------|---------|
| `--scenario=remote_disk` | cross-node SSD read scenario |
| `--role=writer\|reader` | writer prefill, reader benchmark |
| `--protocol=ub` | UB transport (required for GDR) |
| `--device_name` | UB device (comma-separated) |
| `--local_hostname=IP:PORT` | local endpoint |
| `--metadata_server` | master HTTP metadata URL |
| `--master_server` | master gRPC address |
| `--value_size`, `--num_keys`, `--batch_size` | workload shape |
| `--wait_seconds` | wait for peer / offload / eviction |

### GPU flags (reader only)

| Flag | Values | Notes |
|------|--------|-------|
| `--gpu_mode` | `gdr-peermem` \| `staging` \| (empty=host) | gdr-direct/proxy are reserved and FATAL |
| `--gpu_device` | int (default 0) | validated against `cudaGetDeviceCount` |

Gpu mode behavior:

- `gdr-peermem` — GPU VA registered with `is_gpu_seg=1`; NIC DMAs HBM directly
  via peermem.
- `staging` — per-buffer host staging buffer registered to URMA; NIC DMAs host,
  then `cudaMemcpy` H2D.
- host (empty) — CPU memory only; writer must use this.

### Eviction trigger

Offload to SSD happens when
`num_keys * value_size > eviction_high_watermark_ratio * global_segment_size`.
Tune `global_segment_size` (writer) and `eviction_high_watermark_ratio`
(master, default 0.90) accordingly.

### Push vs pull

| Env | Behavior |
|-----|----------|
| (unset) | pull: reader `urma_read` from writer DDR |
| `MC_OFFLOAD_PUSH=true` | push: writer `urma_write` into reader VA |

## 6. Logging & Troubleshooting

### Log levels

| Level | Enable | What you see |
|-------|--------|--------------|
| INFO | default | setup/config milestones, failures |
| VLOG(1) | `MC_VERBOSE=1` | per-buffer register/unregister, staging mapping, URMA registration (`is_gpu_seg`), GPU alloc/free |
| VLOG(2) | `MC_VERBOSE=2` | sampled per-slice transfer: submit branch, D2H/H2D, deferred success, gdr direct source |

Hot-path VLOG(2) is counter-sampled (1 per 10000) to avoid flooding.

### Verification: did it really use SSD -> GDR?

Check the reader breakdown log for the replica type:

- `type[local_disk_remote]` — correct: SSD -> GDR path active.
- `type[memory_remote]` — data still in memory (eviction did not offload).
  Fix by lowering writer `--global_segment_size` or increasing `--num_keys`,
  then rerun.

### Common issues

| Symptom | Cause / Fix |
|---------|------------|
| CMake FATAL_ERROR on `is_gpu_seg` | UMDK too old; point `URMA_ROOT` at a tree with the field |
| reader `type[memory_remote]` | eviction did not trigger; shrink segment or grow data |
| `device pointer not registered for staging` | buffer not `register_buffer`'d before transfer |
| gdr-peermem fails at register | peermem module missing on GPU node |
| mock URMA warning | `liburma.so` not found; GDR unsupported — set `URMA_LIBRARY` |

## 7. Verification Checklist

**Before launch**

- [ ] `nvidia_peermem` (or your custom ko) loaded on GPU node.
- [ ] SSD mount (`/mnt/ssd`) writable on SSD node, with enough free space
      (`>= num_keys * value_size`).
- [ ] `URMA_ROOT` / `URMA_LIBRARY` resolve to a UMDK tree with `is_gpu_seg`.
- [ ] Both nodes reachable; master IP/ports correct.

**During run**

- [ ] master log: `enable_offload` active, no startup errors.
- [ ] writer log: `Offload RPC server started on port ...`, eviction messages,
      data offloaded to SSD.
- [ ] reader log: `Set MC_UB_GPU_MODE=gdr-peermem`, GPU buffer allocated.

**After run**

- [ ] reader `type[local_disk_remote]` present in breakdown logs.
- [ ] `--verify=true` reports `Data verification PASSED`.
- [ ] No `H2D staging copy failed` / `D2H staging copy failed` errors.
