# Roadmap

Future improvements and ideas for the Aspirant platform. Items are grouped by area, not prioritized.

---

## aspirant-assistant (new service)

RAG-based personal assistant for querying uploaded documents (contracts, benefits, law) with role-based access control and citation-grounded answers.

- [ ] Draft spec and architecture (SPEC.md, ARCHITECTURE.md)
- [ ] Scaffold service from `_template/` on port 8088
- [ ] Document upload + parsing pipeline (PDF, DOCX, plain text)
- [ ] Section-aware chunking with page/line metadata preservation
- [ ] pgvector extension on shared PostgreSQL for embedding storage
- [ ] Local embedding model (sentence-transformers, runs on CPU)
- [ ] Local LLM via Ollama (Llama 3.1 8B Q4, CPU-only initially)
- [ ] Retrieval endpoint: query -> embed -> vector search -> ranked chunks
- [ ] Generation endpoint: retrieved chunks -> LLM -> cited answer
- [ ] Citation verification: post-process to confirm references exist in retrieved chunks
- [ ] Role-based document access (admin sees all, family sees tagged subset)
- [ ] Chat UI in aspirant-client with source display (show raw chunks alongside answer)
- [ ] Document management UI (upload, tag, review/correct parsed chunks)
- [ ] OCR support for scanned documents (tesseract)
- [ ] Document structure extraction (table of contents, section hierarchy as metadata)
- [ ] Multi-query retrieval (rephrase to also search for exclusions/conditions)

## GPU upgrade

The cell currently runs an NVIDIA GTX 660 (2GB VRAM, Kepler, compute capability 3.0). Modern LLM inference requires compute capability 5.0+, so all inference is CPU-only.

- [ ] Replace GTX 660 with a modern GPU (RTX 3060 12GB or similar)
- [ ] Install NVIDIA Container Toolkit on the host
- [ ] Add `deploy.resources.reservations.devices` GPU passthrough to docker-compose.yml
- [ ] Validate Ollama auto-detects GPU (no code changes needed in assistant)
- [ ] Re-evaluate model sizes: 13B+ models become viable with 8GB+ VRAM
- [ ] Consider GPU sharing across services (Ollama for assistant, Whisper for transcriber)

## Infrastructure

- [ ] Automated deployment (currently manual `docker compose pull && up`)
- [ ] Backup strategy for pgdata (currently no documented backup)
- [ ] Health check dashboard (monitor service exists but no persistent UI)
- [ ] Log aggregation (currently human-readable logs via `docker compose logs`)
