# TudoBaixa 🎥

Aplicativo de download de vídeos com integração nativa de compartilhamento.

## ✨ Diferencial Principal

Ao invés de copiar e colar links, o **TudoBaixa** aparece diretamente no menu de compartilhamento nativo do Android:

```
Instagram/TikTok/Facebook/YouTube → Compartilhar → TudoBaixa → Download Automático
```

## 🛠️ Tecnologias

| Camada | Tecnologia |
|--------|------------|
| App Mobile | **Flutter / Dart** |
| Backend API | **Python / FastAPI** |
| Download Engine | **yt-dlp** |
| Deploy Gratuito | Render / Railway / Fly.io (free tier) |
| Docker | ✅ Suportado |

## 🏗️ Arquitetura

```
┌───────────────────┐     HTTPS      ┌──────────────────────┐
│  App Flutter      │ ──────────────▶│  FastAPI + yt-dlp    │
│  (Android/iOS)    │ ◀──────────────│  (Free Hosting)      │
└───────────────────┘                └──────────────────────┘
         │                                    │
         ▼                                    ▼
   Share Sheet nativo                  Fila de downloads
   ReceiveSharingIntent                Progresso + temp files
   Download local do .mp4              Auto-limpeza (2h)
```

## 🚀 Começando Rápido

### 1. Rodar o Backend Localmente

```bash
cd backend

# (Opcional) Criar venv
python -m venv venv
venv\Scripts\activate    # Windows
# source venv/bin/activate  # Linux/macOS

# Instalar dependências
pip install -r requirements.txt

# Instalar FFmpeg (necessário para yt-dlp)
# Windows: https://www.gyan.dev/ffmpeg/builds/  (baixe e coloque no PATH)
# macOS: brew install ffmpeg
# Linux: sudo apt install ffmpeg

# Rodar servidor
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

A API estará em: **http://localhost:8000**

Swagger UI: **http://localhost:8000/docs**

### 2. Rodar com Docker

```bash
cd backend
docker compose up --build
```

### 3. Configurar o App Flutter

```bash
cd app
flutter pub get
flutter run        # Para emulador Android
```

#### Configurar URL da API no App

1. Abra o app → toque no ícone ⚙️ (canto superior direito)
2. Cole a URL do seu backend:
   - Emulador Android: `http://10.0.2.2:8000` (acessa o localhost do PC)
   - Dispositivo físico: use o IP da sua rede Wi-Fi + porta 8000 (ex: `http://192.168.0.10:8000`)
   - Deploy em produção: URL do seu servidor gratuito

### 4. Testar o Fluxo de Compartilhamento

1. Certifique-se de que o backend está rodando e a URL está configurada no app.
2. Abra o **Instagram / TikTok / Facebook / YouTube** em um dispositivo Android.
3. Toque em **Compartilhar** em um vídeo.
4. Procure por **TudoBaixa** na lista de apps.
5. Toque nele → **o download começa automaticamente!** 🎉

## 📱 Funcionalidades do App

### ✅ Fluxo Principal (Compartilhamento Nativo)
- [x] Integração com **Android Share Sheet** via `ACTION_SEND` e `ACTION_SEND_MULTIPLE`
- [x] Recebe `text/plain`, `image/*`, `video/*` de outros apps
- [x] Extrai URL automaticamente do conteúdo compartilhado
- [x] Download inicia **sem colar nada**
- [x] Arquitetura preparada para **iOS Share Extension** futuramente

### ✅ Fluxo Secundário (Múltiplos Links)
- [x] Área de texto para colar mensagens completas
- [x] Extrai todas as URLs usando RegEx
- [x] Remove URLs duplicadas automaticamente
- [x] Cria fila com vários downloads simultâneos
- [x] Erro em um vídeo não interrompe os demais

### ✅ Fila e Progresso
- [x] Visualização em tempo real de cada download
- [x] Status: fila → baixando → concluído / erro
- [x] Barra de progresso animada
- [x] Botão para **abrir o vídeo** quando concluído
- [x] Salva em `/storage/emulated/0/Download` (Android)

## 🔌 Endpoints da API

| Método | Rota | Descrição |
|--------|------|-----------|
| `GET` | `/` | Status do serviço |
| `GET` | `/api/health` | Health check |
| `POST` | `/api/download` | Inicia download de 1 URL |
| `POST` | `/api/download/multi` | Extrai URLs de um texto e cria fila |
| `GET` | `/api/status/{task_id}` | Status de 1 tarefa |
| `GET` | `/api/status` | Lista todas as tarefas |
| `GET` | `/api/download/{task_id}/file` | Baixa o arquivo processado |

### Exemplo: Download Simples

```bash
curl -X POST http://localhost:8000/api/download \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}'
```

Resposta:
```json
{
  "task_id": "a1b2c3d4-...",
  "status": "queued",
  "url": "https://..."
}
```

### Exemplo: Múltiplos Links

```bash
curl -X POST http://localhost:8000/api/download/multi \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Olha esses vídeos legais:\nhttps://vm.tiktok.com/ZM123/\nE esse do YouTube: https://youtu.be/abc123\nhttps://vm.tiktok.com/ZM123/ (esse é repetido, será removido)"
  }'
```

## ☁️ Deploy Gratuito do Backend (R$ 0,00)

Escolha UMA das opções abaixo. Todas são gratuitas.

### Opção 1: Render (Recomendado)

1. Acesse: https://render.com
2. Clique em **"New +"** → **"Web Service"**
3. Conecte seu repositório GitHub
4. Preencha:
   - **Build Command**: (deixe vazio, Render usa o Dockerfile automaticamente)
   - **Start Command**: (deixe vazio)
   - **Plan**: **Free** ✅
5. Clique em **Create Web Service**
6. Espere buildar (~3-5 min)
7. Copie a URL (ex: `https://video-downloader-api.onrender.com`) e configure no app.

**Ou use o arquivo `render.yaml` existente no repositório.**

### Opção 2: Railway

1. Acesse: https://railway.app
2. **New Project** → **Deploy from GitHub repo**
3. Selecione o projeto e aguarde o deploy automático (ele lê o `railway.json`)
4. Vá em **Settings** → **Networking** → **Generate Domain** para pegar a URL

### Opção 3: Fly.io

1. Instale o Fly CLI: `powershell -Command "iwr https://fly.io/install.ps1 -useb | iex"`
2. `fly auth signup` (crie a conta gratuita)
3. `cd backend && fly launch --no-deploy`
4. `fly deploy` (o `fly.toml` já está configurado)
5. `fly status` para pegar a URL

### ⚠️ Limitações do Free Tier

| Recurso | Observação |
|---------|-----------|
| Sleep/Auto-Stop | Serviços gratuitos dormem após período sem uso → a primeira requisição pode demorar ~10s para "acordar" |
| Limite de RAM | 512MB free (suficiente para yt-dlp) |
| Largura de banda | 100GB/mês gratuita na maioria |

💡 **Dica**: O app flutter pode mostrar um aviso na primeira requisição lenta.

## 🎯 Gerar APK de Release

```bash
cd app

# Gerar APK (instalável diretamente em dispositivos Android)
flutter build apk --release

# Gerar App Bundle (para publicar na Play Store)
flutter build appbundle --release
```

O APK ficará em: `app/build/app/outputs/flutter-apk/app-release.apk`

## 🗂️ Estrutura do Projeto

```
TudoBaixa/
├── backend/
│   ├── main.py              # FastAPI + lógica de download yt-dlp
│   ├── requirements.txt     # Dependências Python
│   ├── Dockerfile           # Imagem Docker
│   ├── docker-compose.yml   # Para rodar local com docker
│   ├── render.yaml          # Configuração Render (deploy gratuito)
│   ├── railway.json         # Configuração Railway
│   └── fly.toml             # Configuração Fly.io
├── app/
│   ├── lib/
│   │   └── main.dart        # App Flutter completo (UI + integrações)
│   ├── android/
│   │   └── app/src/main/
│   │       ├── AndroidManifest.xml   # ← Share Sheet configurado aqui (ACTION_SEND)
│   │       └── kotlin/.../MainActivity.kt
│   ├── ios/                 # Preparado para Share Extension futuramente
│   └── pubspec.yaml
└── README.md                # Este arquivo
```

## ✅ Critérios de Pronto do MVP

- [x] Instagram/TikTok/Facebook/YouTube → Compartilhar → **TudoBaixa aparece na lista**
- [x] Toque no app → **URL recebida automaticamente**
- [x] Download **inicia sem precisar colar link**
- [x] Mostra **progresso e status** em tempo real
- [x] Vídeo **disponível no celular** e botão de abrir
- [x] Colar texto com 15 links → **15 downloads em fila**
- [x] URLs duplicadas são **removidas**
- [x] Uma falha **não interrompe** os outros
- [x] Backend roda em **hospedagem gratuita** (R$ 0,00)
- [x] Funciona com **o PC desligado** (após deploy)

## 📋 Próximos Passos (Fora do MVP)

- [ ] iOS Share Extension nativo
- [ ] Suporte a download de áudio (MP3)
- [ ] Histórico persistente
- [ ] Escolher qualidade/resolução
- [ ] Notificações locais quando downloads terminam

## ❗ Aviso Legal

Este projeto é para **uso pessoal e portfólio**. Respeite os Termos de Servício das plataformas e os direitos autorais dos criadores de conteúdo. Só baixe vídeos que você tem permissão para baixar.

---

**Feito com ❤️ por Vibe Coding** • Custo total: **R$ 0,00**
