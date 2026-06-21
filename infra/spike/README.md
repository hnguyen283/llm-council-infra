# P0 — Local AI spike harness

Runs Ollama with the DeepSeek-R1 1.5B distill against a 50-query corpus on
the target hardware (NVIDIA Quadro M2000M, 4 GB VRAM). The exit criteria
from the design doc are:

| Metric | Threshold |
|---|---|
| Median latency | < 4 s |
| VRAM peak | < 4 GB (Q4_K_M, single model loaded) |
| JSON-schema validity | ≥ 95% |
| First-token latency on cold start | < 30 s |

If all four hold, raise the P1 tickets in the design doc.

## Prerequisites

- Docker Desktop with the **NVIDIA Container Toolkit** enabled
- NVIDIA driver ≥ 535 (CUDA 12.2 or newer; check with `nvidia-smi`)
- Roughly 5 GB free disk for the model cache volume
- Python 3.10+ on the host (for `bench.py`)

## Run the spike

```bash
cd infra/spike/ollama

# 1. Bring up Ollama (GPU passthrough)
docker compose up -d
docker compose logs -f ollama   # wait for "Listening on [::]:11434"

# 2. Pull the model and create the planner alias
docker compose exec ollama ollama pull deepseek-r1:7b
docker compose exec ollama ollama create planner -f /Modelfile.planner

# 3. (separate terminal) watch VRAM while the bench runs
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv -l 1

# 4. Run the benchmark
cd ..
python bench.py --model planner --queries queries.txt --out bench-results.json
```

The script prints a JSON summary and writes the full per-query results to
`bench-results.json`. A non-zero exit code indicates that schema validity
fell below 95%.

## Optional: capped GPU-layer 7B run

To probe whether the 7B distill is viable with partial CPU offload (the
optional Tier-B path), pull the model and create a second alias with a
capped GPU layer count:

```bash
docker compose exec ollama ollama pull deepseek-r1:7b
cat > Modelfile.planner-7b <<'EOF'
FROM deepseek-r1:7b
PARAMETER num_gpu 16
PARAMETER num_ctx 4096
PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER num_predict 512
SYSTEM """(same SYSTEM as Modelfile.planner)"""
EOF
docker compose cp Modelfile.planner-7b ollama:/Modelfile.planner-7b
docker compose exec ollama ollama create planner-7b -f /Modelfile.planner-7b

python bench.py --model planner-7b --queries queries.txt --out bench-7b-results.json
```

Expect 5–10 tokens/sec on the M2000M with 16 of 33 layers on GPU. If the
7B path stays under 4 GB and produces clean JSON ≥ 95% of the time, it
becomes a candidate for Tier-B in P4.

## Tear down

```bash
docker compose down -v          # -v removes the 5 GB model cache
```
