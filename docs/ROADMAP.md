# Roadmap

Future improvements and ideas for the Aspirant platform. Items are grouped by area, not prioritized.

---

## aspirant-advisor (shipped 2026-03-22)

RAG-based personal assistant for querying uploaded documents (contracts, benefits, law) with role-based access control and citation-grounded answers.

- [x] Draft spec and architecture (SPEC.md, ARCHITECTURE.md)
- [x] Scaffold service on port 8088
- [x] Document upload + parsing pipeline (PDF, DOCX, plain text)
- [x] Section-aware chunking with page/line metadata preservation
- [x] pgvector extension on shared PostgreSQL for embedding storage
- [x] Local embedding model (sentence-transformers all-MiniLM-L6-v2, runs on CPU)
- [x] Local LLM via Ollama (Llama 3.1 8B Q4_K_M, CPU-only)
- [x] Retrieval endpoint: query -> embed -> vector search -> ranked chunks
- [x] Generation endpoint: retrieved chunks -> LLM -> cited answer
- [x] Citation verification: post-process to confirm references exist in retrieved chunks
- [x] Role-based document access (admin sees all, family sees tagged subset)
- [x] Source registry with gap indicators (empty domains shown explicitly)
- [x] Three-tier law support (Tier 1 full text, Tier 2 indexed references)
- [x] Chat UI in aspirant-client with citation display
- [x] Document management UI (upload, delete) — admin only
- [x] Server proxy handlers (Go) with 120s timeout for LLM generation
- [x] CI/CD pipeline with pgvector test database
- [ ] OCR support for scanned documents (tesseract)
- [ ] Document structure extraction (table of contents, section hierarchy as metadata)
- [ ] Multi-query retrieval (rephrase to also search for exclusions/conditions)
- [ ] Conversation history (multi-turn chat with context window)
- [ ] Domain filtering in chat UI (restrict query to specific domains)

## GPU upgrade

The cell currently runs an NVIDIA GTX 660 (2GB VRAM, Kepler, compute capability 3.0). Modern LLM inference requires compute capability 5.0+, so all inference is CPU-only.

- [ ] Replace GTX 660 with a modern GPU (RTX 3060 12GB or similar)
- [ ] Install NVIDIA Container Toolkit on the host
- [ ] Add `deploy.resources.reservations.devices` GPU passthrough to docker-compose.yml
- [ ] Validate Ollama auto-detects GPU (no code changes needed in advisor)
- [ ] Re-evaluate model sizes: 13B+ models become viable with 8GB+ VRAM
- [ ] Consider GPU sharing across services (Ollama for advisor, Whisper for transcriber)

## Infrastructure

- [ ] Automated deployment (currently manual `docker compose pull && up`)
- [ ] Backup strategy for pgdata (currently no documented backup)
- [ ] Health check dashboard (monitor service exists but no persistent UI)
- [ ] Log aggregation (currently human-readable logs via `docker compose logs`)
