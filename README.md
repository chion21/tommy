# টমি (Tommy) – বাংলা ভয়েস AI অ্যাসিস্ট্যান্ট

পুরো পরিকল্পনা আর কাজের অবস্থা: **[TOMMY_CONTEXT.md](TOMMY_CONTEXT.md)** (যেকোনো AI-কে এই ফাইলটা দিলেই সব বুঝবে)

## ফোল্ডার
| ফোল্ডার | কী আছে |
|---|---|
| `server/` | লাইসেন্স, লগইন, ডিভাইস লিমিট, নাম/থিম/কণ্ঠ/ভাষা, মেমোরি, AI-মিনিট, Gemini টোকেন, অ্যাডমিন (FastAPI) |
| `app/` | ফোন + PC অ্যাপ (Flutter, একই কোড) |
| `.github/workflows/` | GitHub-এ কোড দিলেই APK আর `TommySetup.exe` অটো তৈরি হয় |

## সার্ভার নিজের কম্পিউটারে চালিয়ে দেখা
```bash
cd server
pip install -r requirements-dev.txt
pytest -q                                   # সব টেস্ট
ADMIN_API_KEY=test uvicorn app.main:app --reload
# ব্রাউজারে http://127.0.0.1:8000/docs  → সব API হাতে চালিয়ে দেখা যায়
```

## VPS-এ সার্ভার চালু (একবার)
```bash
git clone <তোমার রিপো> && cd tommy/server
cp .env.example .env && nano .env      # গোপন মানগুলো বসাও
nano Caddyfile                          # YOUR-NAME.duckdns.org (ফ্রি) বা নিজের ডোমেইন বসাও
docker compose up -d
```

## লাইসেন্স কী বানানো (বিক্রির পর)
```bash
curl -X POST https://api.YOUR-DOMAIN.com/admin/licenses \
  -H "X-Admin-Key: <ADMIN_API_KEY>" -H "Content-Type: application/json" \
  -d '{"plan":"yearly","days":365,"count":1,"note":"রাকিব, bKash TrxID ..."}'
```

## অ্যাপ বিল্ড
GitHub রিপোতে **Settings → Secrets and variables → Actions → Variables**-এ `API_URL` = `https://api.YOUR-DOMAIN.com` দাও।
তারপর **Actions → build-apps → Run workflow**। শেষ হলে নিচে "Artifacts"-এ APK আর Setup.exe পাবে।
