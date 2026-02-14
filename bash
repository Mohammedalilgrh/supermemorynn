mkdir -p data/backup data/large

# إنشاء ملفات البيانات الأولية
echo '{}' > data/database.json
echo '{}' > data/sessions.json
echo '{}' > data/memory.json
echo '{}' > data/users.json

git add .
git commit -m "🆕 تهيئة ملفات البيانات"
git push
