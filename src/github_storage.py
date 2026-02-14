import os
import json
import base64
import hashlib
import time
import threading
import requests
from datetime import datetime
from typing import Any, Dict, Optional, List
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("GitHubStorage")


class GitHubStorage:
    """
    نظام تخزين دائم على GitHub - يحفظ كل البيانات في الريبو
    مجاني - بلا حدود عملية - يبقى مدى الحياة
    """
    
    def __init__(self):
        # إعدادات GitHub
        self.github_token = os.environ.get("GITHUB_TOKEN")
        self.repo_owner = os.environ.get("GITHUB_REPO_OWNER")  # اسم المستخدم
        self.repo_name = os.environ.get("GITHUB_REPO_NAME")    # اسم الريبو
        self.branch = os.environ.get("GITHUB_BRANCH", "main")
        
        if not all([self.github_token, self.repo_owner, self.repo_name]):
            raise ValueError(
                "يجب تعيين GITHUB_TOKEN, GITHUB_REPO_OWNER, GITHUB_REPO_NAME"
            )
        
        self.base_url = f"https://api.github.com/repos/{self.repo_owner}/{self.repo_name}"
        self.headers = {
            "Authorization": f"token {self.github_token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json"
        }
        
        # كاش محلي لتقليل الطلبات
        self._cache: Dict[str, Any] = {}
        self._cache_sha: Dict[str, str] = {}  # SHA لكل ملف
        self._dirty: set = set()  # ملفات تحتاج حفظ
        
        # قفل للتعامل مع التزامن
        self._lock = threading.Lock()
        
        # تحميل كل البيانات عند البدء
        self._load_all_data()
        
        # حفظ تلقائي كل 30 ثانية
        self._auto_save_interval = 30
        self._start_auto_save()
        
        logger.info("✅ نظام التخزين على GitHub جاهز!")
    
    # ============================================
    # الوظائف الأساسية للتعامل مع GitHub API
    # ============================================
    
    def _github_request(self, method: str, endpoint: str, 
                         data: dict = None, retries: int = 3) -> Optional[dict]:
        """إرسال طلب لـ GitHub API مع إعادة المحاولة"""
        url = f"{self.base_url}/{endpoint}"
        
        for attempt in range(retries):
            try:
                if method == "GET":
                    response = requests.get(url, headers=self.headers, timeout=30)
                elif method == "PUT":
                    response = requests.put(
                        url, headers=self.headers, 
                        json=data, timeout=30
                    )
                elif method == "DELETE":
                    response = requests.delete(
                        url, headers=self.headers, 
                        json=data, timeout=30
                    )
                
                if response.status_code in [200, 201]:
                    return response.json()
                elif response.status_code == 404:
                    return None
                elif response.status_code == 409:
                    # conflict - نحتاج نحدث SHA
                    logger.warning(f"⚠️ تعارض في {endpoint}, جاري إعادة المحاولة...")
                    time.sleep(1)
                    # تحديث SHA
                    file_path = endpoint.replace("contents/", "")
                    self._refresh_sha(file_path)
                    continue
                elif response.status_code == 422:
                    logger.warning(f"⚠️ خطأ 422 في {endpoint}, جاري تحديث SHA...")
                    file_path = endpoint.replace("contents/", "")
                    self._refresh_sha(file_path)
                    continue
                elif response.status_code == 403:
                    # Rate limit
                    reset_time = int(
                        response.headers.get("X-RateLimit-Reset", time.time() + 60)
                    )
                    wait = max(reset_time - int(time.time()), 1)
                    logger.warning(f"⚠️ حد الطلبات، انتظار {wait} ثانية...")
                    time.sleep(min(wait, 60))
                    continue
                else:
                    logger.error(
                        f"❌ خطأ {response.status_code}: {response.text[:200]}"
                    )
                    
            except requests.exceptions.Timeout:
                logger.warning(f"⏰ انتهت المهلة، محاولة {attempt + 1}/{retries}")
                time.sleep(2)
            except Exception as e:
                logger.error(f"❌ خطأ: {e}")
                time.sleep(2)
        
        return None
    
    def _refresh_sha(self, file_path: str):
        """تحديث SHA لملف معين"""
        result = self._github_request("GET", f"contents/{file_path}?ref={self.branch}")
        if result and "sha" in result:
            self._cache_sha[file_path] = result["sha"]
    
    def _read_file(self, file_path: str) -> Optional[Any]:
        """قراءة ملف من GitHub"""
        result = self._github_request(
            "GET", f"contents/{file_path}?ref={self.branch}"
        )
        
        if result and "content" in result:
            self._cache_sha[file_path] = result["sha"]
            content = base64.b64decode(result["content"]).decode("utf-8")
            try:
                return json.loads(content)
            except json.JSONDecodeError:
                return content
        
        return None
    
    def _write_file(self, file_path: str, data: Any, 
                     message: str = None) -> bool:
        """كتابة ملف إلى GitHub"""
        if message is None:
            message = f"📦 تحديث {file_path} - {datetime.now().isoformat()}"
        
        # تحويل البيانات لـ JSON
        if isinstance(data, (dict, list)):
            content = json.dumps(data, ensure_ascii=False, indent=2)
        else:
            content = str(data)
        
        # تشفير بـ base64
        encoded = base64.b64encode(content.encode("utf-8")).decode("utf-8")
        
        payload = {
            "message": message,
            "content": encoded,
            "branch": self.branch
        }
        
        # إضافة SHA إذا الملف موجود (للتحديث)
        if file_path in self._cache_sha:
            payload["sha"] = self._cache_sha[file_path]
        
        result = self._github_request("PUT", f"contents/{file_path}", payload)
        
        if result and "content" in result:
            self._cache_sha[file_path] = result["content"]["sha"]
            logger.info(f"✅ تم حفظ {file_path}")
            return True
        
        return False
    
    # ============================================
    # إدارة البيانات
    # ============================================
    
    def _load_all_data(self):
        """تحميل كل البيانات من GitHub عند البدء"""
        logger.info("📥 جاري تحميل البيانات من GitHub...")
        
        data_files = [
            "data/database.json",
            "data/sessions.json", 
            "data/memory.json",
            "data/users.json"
        ]
        
        for file_path in data_files:
            data = self._read_file(file_path)
            if data is not None:
                self._cache[file_path] = data
                logger.info(f"  ✅ تم تحميل {file_path}")
            else:
                # إنشاء ملف جديد فارغ
                self._cache[file_path] = {}
                self._write_file(file_path, {}, f"🆕 إنشاء {file_path}")
                logger.info(f"  🆕 تم إنشاء {file_path}")
        
        logger.info(f"📥 تم تحميل {len(self._cache)} ملف بيانات")
    
    def _start_auto_save(self):
        """بدء الحفظ التلقائي"""
        def auto_save():
            while True:
                time.sleep(self._auto_save_interval)
                self.save_all()
        
        thread = threading.Thread(target=auto_save, daemon=True)
        thread.start()
        logger.info(
            f"⏰ حفظ تلقائي كل {self._auto_save_interval} ثانية"
        )
    
    def save_all(self):
        """حفظ كل البيانات المتغيرة"""
        with self._lock:
            if not self._dirty:
                return
            
            dirty_copy = self._dirty.copy()
            self._dirty.clear()
        
        for file_path in dirty_copy:
            if file_path in self._cache:
                success = self._write_file(self._cache[file_path], file_path)
                if not success:
                    # إعادة للقائمة إذا فشل الحفظ
                    with self._lock:
                        self._dirty.add(file_path)
    
    def force_save_all(self):
        """حفظ إجباري لكل البيانات"""
        with self._lock:
            for file_path, data in self._cache.items():
                self._write_file(file_path, data)
        logger.info("💾 تم الحفظ الإجباري لكل البيانات")
    
    # ============================================
    # واجهة قاعدة البيانات
    # ============================================
    
    def get_db(self, collection: str = "default") -> dict:
        """الحصول على مجموعة بيانات"""
        file_path = "data/database.json"
        with self._lock:
            if file_path not in self._cache:
                self._cache[file_path] = {}
            db = self._cache[file_path]
            if collection not in db:
                db[collection] = {}
            return db[collection]
    
    def set_value(self, collection: str, key: str, value: Any):
        """تعيين قيمة في قاعدة البيانات"""
        file_path = "data/database.json"
        with self._lock:
            if file_path not in self._cache:
                self._cache[file_path] = {}
            if collection not in self._cache[file_path]:
                self._cache[file_path][collection] = {}
            self._cache[file_path][collection][key] = value
            self._dirty.add(file_path)
    
    def get_value(self, collection: str, key: str, 
                   default: Any = None) -> Any:
        """الحصول على قيمة من قاعدة البيانات"""
        file_path = "data/database.json"
        with self._lock:
            db = self._cache.get(file_path, {})
            return db.get(collection, {}).get(key, default)
    
    def delete_value(self, collection: str, key: str) -> bool:
        """حذف قيمة من قاعدة البيانات"""
        file_path = "data/database.json"
        with self._lock:
            if file_path in self._cache:
                if collection in self._cache[file_path]:
                    if key in self._cache[file_path][collection]:
                        del self._cache[file_path][collection][key]
                        self._dirty.add(file_path)
                        return True
        return False
    
    def list_keys(self, collection: str) -> list:
        """قائمة المفاتيح في مجموعة"""
        file_path = "data/database.json"
        with self._lock:
            db = self._cache.get(file_path, {})
            return list(db.get(collection, {}).keys())
    
    def search(self, collection: str, 
                query: Dict[str, Any]) -> List[dict]:
        """بحث في مجموعة بيانات"""
        file_path = "data/database.json"
        results = []
        with self._lock:
            db = self._cache.get(file_path, {})
            items = db.get(collection, {})
            for key, value in items.items():
                if isinstance(value, dict):
                    match = all(
                        value.get(qk) == qv 
                        for qk, qv in query.items()
                    )
                    if match:
                        results.append({"_key": key, **value})
        return results
    
    # ============================================
    # إدارة الجلسات (Sessions)
    # ============================================
    
    def save_session(self, session_name: str, session_data: Any):
        """حفظ جلسة"""
        file_path = "data/sessions.json"
        with self._lock:
            if file_path not in self._cache:
                self._cache[file_path] = {}
            
            # إذا كانت البيانات bytes، نحولها لـ base64
            if isinstance(session_data, bytes):
                self._cache[file_path][session_name] = {
                    "type": "bytes",
                    "data": base64.b64encode(session_data).decode("utf-8"),
                    "saved_at": datetime.now().isoformat()
                }
            elif isinstance(session_data, str):
                self._cache[file_path][session_name] = {
                    "type": "string",
                    "data": session_data,
                    "saved_at": datetime.now().isoformat()
                }
            else:
                self._cache[file_path][session_name] = {
                    "type": "json",
                    "data": session_data,
                    "saved_at": datetime.now().isoformat()
                }
            
            self._dirty.add(file_path)
        
        # حفظ فوري للجلسات المهمة
        self._write_file(file_path, self._cache[file_path])
        logger.info(f"✅ تم حفظ الجلسة: {session_name}")
    
    def load_session(self, session_name: str) -> Optional[Any]:
        """تحميل جلسة"""
        file_path = "data/sessions.json"
        with self._lock:
            sessions = self._cache.get(file_path, {})
            session = sessions.get(session_name)
            
            if session is None:
                return None
            
            if session["type"] == "bytes":
                return base64.b64decode(session["data"])
            elif session["type"] == "string":
                return session["data"]
            else:
                return session["data"]
    
    def delete_session(self, session_name: str) -> bool:
        """حذف جلسة"""
        file_path = "data/sessions.json"
        with self._lock:
            if file_path in self._cache:
                if session_name in self._cache[file_path]:
                    del self._cache[file_path][session_name]
                    self._dirty.add(file_path)
                    return True
        return False
    
    def list_sessions(self) -> list:
        """قائمة الجلسات"""
        file_path = "data/sessions.json"
        with self._lock:
            return list(self._cache.get(file_path, {}).keys())
    
    # ============================================
    # إدارة الذاكرة (Memory)
    # ============================================
    
    def remember(self, key: str, value: Any, 
                  category: str = "general"):
        """حفظ شيء في الذاكرة"""
        file_path = "data/memory.json"
        with self._lock:
            if file_path not in self._cache:
                self._cache[file_path] = {}
            if category not in self._cache[file_path]:
                self._cache[file_path][category] = {}
            
            self._cache[file_path][category][key] = {
                "value": value,
                "remembered_at": datetime.now().isoformat(),
                "access_count": 0
            }
            self._dirty.add(file_path)
    
    def recall(self, key: str, category: str = "general") -> Optional[Any]:
        """استرجاع شيء من الذاكرة"""
        file_path = "data/memory.json"
        with self._lock:
            memory = self._cache.get(file_path, {})
            cat = memory.get(category, {})
            item = cat.get(key)
            
            if item:
                item["access_count"] = item.get("access_count", 0) + 1
                item["last_accessed"] = datetime.now().isoformat()
                self._dirty.add(file_path)
                return item["value"]
        
        return None
    
    def forget(self, key: str, category: str = "general") -> bool:
        """نسيان شيء من الذاكرة"""
        file_path = "data/memory.json"
        with self._lock:
            memory = self._cache.get(file_path, {})
            if category in memory and key in memory[category]:
                del memory[category][key]
                self._dirty.add(file_path)
                return True
        return False
    
    def recall_all(self, category: str = "general") -> dict:
        """استرجاع كل الذاكرة في فئة"""
        file_path = "data/memory.json"
        with self._lock:
            memory = self._cache.get(file_path, {})
            cat = memory.get(category, {})
            return {k: v["value"] for k, v in cat.items()}
    
    # ============================================
    # إدارة المستخدمين
    # ============================================
    
    def save_user(self, user_id: str, user_data: dict):
        """حفظ بيانات مستخدم"""
        file_path = "data/users.json"
        with self._lock:
            if file_path not in self._cache:
                self._cache[file_path] = {}
            
            if user_id in self._cache[file_path]:
                self._cache[file_path][user_id].update(user_data)
            else:
                self._cache[file_path][user_id] = user_data
            
            self._cache[file_path][user_id]["updated_at"] = (
                datetime.now().isoformat()
            )
            self._dirty.add(file_path)
    
    def get_user(self, user_id: str) -> Optional[dict]:
        """الحصول على بيانات مستخدم"""
        file_path = "data/users.json"
        with self._lock:
            return self._cache.get(file_path, {}).get(user_id)
    
    def get_all_users(self) -> dict:
        """الحصول على كل المستخدمين"""
        file_path = "data/users.json"
        with self._lock:
            return self._cache.get(file_path, {}).copy()
    
    def delete_user(self, user_id: str) -> bool:
        """حذف مستخدم"""
        file_path = "data/users.json"
        with self._lock:
            if file_path in self._cache:
                if user_id in self._cache[file_path]:
                    del self._cache[file_path][user_id]
                    self._dirty.add(file_path)
                    return True
        return False
    
    # ============================================
    # تخزين الملفات الكبيرة (تقسيم تلقائي)
    # ============================================
    
    def save_large_data(self, name: str, data: Any) -> bool:
        """
        حفظ بيانات كبيرة - يقسمها تلقائياً إذا تجاوزت 50MB
        GitHub يسمح بملفات حتى 100MB
        """
        content = json.dumps(data, ensure_ascii=False)
        size_mb = len(content.encode("utf-8")) / (1024 * 1024)
        
        if size_mb < 50:
            # ملف واحد
            return self._write_file(f"data/large/{name}.json", data)
        else:
            # تقسيم
            chunk_size = 40 * 1024 * 1024  # 40MB per chunk
            chunks = []
            content_bytes = content.encode("utf-8")
            
            for i in range(0, len(content_bytes), chunk_size):
                chunk = content_bytes[i:i + chunk_size]
                chunks.append(chunk)
            
            # حفظ معلومات التقسيم
            meta = {
                "name": name,
                "total_chunks": len(chunks),
                "total_size": len(content_bytes),
                "created_at": datetime.now().isoformat()
            }
            self._write_file(f"data/large/{name}_meta.json", meta)
            
            # حفظ كل جزء
            for i, chunk in enumerate(chunks):
                chunk_b64 = base64.b64encode(chunk).decode("utf-8")
                self._write_file(
                    f"data/large/{name}_chunk_{i}.json",
                    {"chunk": i, "data": chunk_b64}
                )
            
            logger.info(
                f"✅ تم حفظ {name} ({size_mb:.1f}MB) "
                f"في {len(chunks)} أجزاء"
            )
            return True
    
    def load_large_data(self, name: str) -> Optional[Any]:
        """تحميل بيانات كبيرة"""
        # محاولة ملف واحد أولاً
        data = self._read_file(f"data/large/{name}.json")
        if data is not None:
            return data
        
        # محاولة ملف مقسم
        meta = self._read_file(f"data/large/{name}_meta.json")
        if meta is None:
            return None
        
        # تجميع الأجزاء
        all_bytes = b""
        for i in range(meta["total_chunks"]):
            chunk_data = self._read_file(
                f"data/large/{name}_chunk_{i}.json"
            )
            if chunk_data:
                all_bytes += base64.b64decode(chunk_data["data"])
        
        return json.loads(all_bytes.decode("utf-8"))
    
    # ============================================
    # نسخ احتياطي
    # ============================================
    
    def create_backup(self) -> bool:
        """إنشاء نسخة احتياطية"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        for file_path, data in self._cache.items():
            backup_path = file_path.replace(
                "data/", f"data/backup/{timestamp}/"
            )
            self._write_file(
                backup_path, data,
                f"🔒 نسخة احتياطية {timestamp}"
            )
        
        logger.info(f"🔒 تم إنشاء نسخة احتياطية: {timestamp}")
        return True
    
    # ============================================
    # إحصائيات
    # ============================================
    
    def get_stats(self) -> dict:
        """إحصائيات التخزين"""
        stats = {
            "total_files": len(self._cache),
            "dirty_files": len(self._dirty),
            "collections": {},
            "sessions_count": 0,
            "memory_categories": 0,
            "users_count": 0
        }
        
        # قاعدة البيانات
        db = self._cache.get("data/database.json", {})
        for col_name, col_data in db.items():
            stats["collections"][col_name] = len(col_data)
        
        # الجلسات
        sessions = self._cache.get("data/sessions.json", {})
        stats["sessions_count"] = len(sessions)
        
        # الذاكرة
        memory = self._cache.get("data/memory.json", {})
        stats["memory_categories"] = len(memory)
        stats["total_memories"] = sum(
            len(v) for v in memory.values()
        )
        
        # المستخدمين
        users = self._cache.get("data/users.json", {})
        stats["users_count"] = len(users)
        
        return stats
    
    def __del__(self):
        """حفظ كل شيء عند الإغلاق"""
        try:
            self.force_save_all()
        except Exception:
            pass


# ============================================
# Singleton - نسخة واحدة من التخزين
# ============================================

_storage_instance = None


def get_storage() -> GitHubStorage:
    """الحصول على نسخة التخزين (Singleton)"""
    global _storage_instance
    if _storage_instance is None:
        _storage_instance = GitHubStorage()
    return _storage_instance
