/// App text in Bangla / English / Hindi. `{name}` is replaced with the assistant's name.
const _strings = <String, Map<String, String>>{
  'hello': {'bn': 'হ্যালো, {user}', 'en': 'Hello, {user}', 'hi': 'नमस्ते, {user}'},
  'subtitle': {'bn': 'আজ কীভাবে সাহায্য করতে পারি?', 'en': 'How can I assist you today?', 'hi': 'आज मैं कैसे मदद करूँ?'},
  'ask': {'bn': '{name}-কে কিছু জিজ্ঞেস করুন…', 'en': 'Ask {name} anything…', 'hi': '{name} से कुछ भी पूछें…'},
  'home': {'bn': 'হোম', 'en': 'Home', 'hi': 'होम'},
  'chat': {'bn': 'চ্যাট', 'en': 'Chat', 'hi': 'चैट'},
  'triggers': {'bn': 'ট্রিগার', 'en': 'Triggers', 'hi': 'ट्रिगर'},
  'settings': {'bn': 'সেটিংস', 'en': 'Settings', 'hi': 'सेटिंग्स'},
  'idle': {'bn': '"হেই {name}" বলুন', 'en': 'Say "Hey {name}"', 'hi': '"हे {name}" बोलें'},
  'listening': {'bn': 'শুনছি…', 'en': 'Listening…', 'hi': 'सुन रही हूँ…'},
  'thinking': {'bn': 'ভাবছি…', 'en': 'Thinking…', 'hi': 'सोच रही हूँ…'},
  'speaking': {'bn': 'বলছি…', 'en': 'Speaking…', 'hi': 'बोल रही हूँ…'},
  'login': {'bn': 'লগইন', 'en': 'Log in', 'hi': 'लॉग इन'},
  'register': {'bn': 'নতুন অ্যাকাউন্ট', 'en': 'Create account', 'hi': 'नया खाता'},
  'phone_or_email': {'bn': 'ফোন নম্বর বা ইমেইল', 'en': 'Phone or email', 'hi': 'फ़ोन या ईमेल'},
  'password': {'bn': 'পাসওয়ার্ড', 'en': 'Password', 'hi': 'पासवर्ड'},
  'your_name': {'bn': 'আপনার নাম', 'en': 'Your name', 'hi': 'आपका नाम'},
  'license_key': {'bn': 'লাইসেন্স কী', 'en': 'License key', 'hi': 'लाइसेंस की'},
  'activate': {'bn': 'চালু করুন', 'en': 'Activate', 'hi': 'चालू करें'},
  'assistant_name': {'bn': 'অ্যাসিস্ট্যান্টের নাম', 'en': 'Assistant name', 'hi': 'असिस्टेंट का नाम'},
  'renames_left': {'bn': 'আর {n} বার নাম বদলাতে পারবেন', 'en': '{n} name changes left', 'hi': '{n} बार नाम बदल सकते हैं'},
  'theme': {'bn': 'থিম', 'en': 'Theme', 'hi': 'थीम'},
  'voice': {'bn': 'কণ্ঠ', 'en': 'Voice', 'hi': 'आवाज़'},
  'female': {'bn': 'মেয়েলি', 'en': 'Female', 'hi': 'महिला'},
  'male': {'bn': 'ছেলে', 'en': 'Male', 'hi': 'पुरुष'},
  'app_language': {'bn': 'অ্যাপের ভাষা', 'en': 'App language', 'hi': 'ऐप की भाषा'},
  'talk_language': {'bn': 'কথা বলার ভাষা', 'en': 'Talking language', 'hi': 'बात करने की भाषा'},
  'auto': {'bn': 'অটো (যে ভাষায় বলবেন)', 'en': 'Auto (match my language)', 'hi': 'ऑटो (मेरी भाषा में)'},
  'memory': {'bn': 'মেমোরি', 'en': 'Memory', 'hi': 'मेमोरी'},
  'memory_hint': {'bn': '{name} আপনার সম্পর্কে যা মনে রেখেছে', 'en': 'What {name} remembers about you', 'hi': '{name} को आपके बारे में क्या याद है'},
  'add': {'bn': 'যোগ করুন', 'en': 'Add', 'hi': 'जोड़ें'},
  'save': {'bn': 'সেভ', 'en': 'Save', 'hi': 'सेव'},
  'logout': {'bn': 'লগআউট', 'en': 'Log out', 'hi': 'लॉग आउट'},
  'plan': {'bn': 'প্ল্যান', 'en': 'Plan', 'hi': 'प्लान'},
  'ai_minutes_left': {'bn': 'AI-মিনিট বাকি: {n}', 'en': 'AI minutes left: {n}', 'hi': 'AI मिनट बाकी: {n}'},
  'replace_device_q': {'bn': 'অন্য একটা ডিভাইস চালু আছে। সেটা সরিয়ে এখানে চালু করবেন?', 'en': 'Another device is active. Remove it and use this one?', 'hi': 'दूसरा डिवाइस चालू है। उसे हटाकर यहाँ चालू करें?'},
  'server': {'bn': 'সার্ভারের ঠিকানা', 'en': 'Server address', 'hi': 'सर्वर का पता'},
  'yes': {'bn': 'হ্যাঁ', 'en': 'Yes', 'hi': 'हाँ'},
  'no': {'bn': 'না', 'en': 'No', 'hi': 'नहीं'},
  'coming_soon': {'bn': 'শিগগিরই আসছে', 'en': 'Coming soon', 'hi': 'जल्द आ रहा है'},
};

/// Server error codes → friendly text.
const _errors = <String, Map<String, String>>{
  'BAD_LOGIN': {'bn': 'ফোন/ইমেইল বা পাসওয়ার্ড ভুল', 'en': 'Wrong phone/email or password', 'hi': 'फ़ोन/ईमेल या पासवर्ड गलत'},
  'LOGIN_TAKEN': {'bn': 'এই নম্বর/ইমেইল আগেই ব্যবহার হয়েছে', 'en': 'Already registered', 'hi': 'पहले से रजिस्टर है'},
  'SWAP_LIMIT': {'bn': '৩০ দিনে ২ বারের বেশি ডিভাইস বদলানো যায় না', 'en': 'Device can change only 2 times in 30 days', 'hi': '30 दिन में 2 बार से ज़्यादा डिवाइस नहीं बदल सकते'},
  'BAD_KEY': {'bn': 'লাইসেন্স কী সঠিক নয়', 'en': 'License key not valid', 'hi': 'लाइसेंस की सही नहीं'},
  'KEY_USED': {'bn': 'এই কী আগেই ব্যবহার হয়েছে', 'en': 'This key was already used', 'hi': 'यह की पहले ही इस्तेमाल हो चुकी'},
  'RENAME_LIMIT': {'bn': 'নাম সর্বোচ্চ ৫ বার বদলানো যায়', 'en': 'Name can be changed at most 5 times', 'hi': 'नाम अधिकतम 5 बार बदल सकते हैं'},
  'NAME_TOO_SHORT': {'bn': 'নাম কমপক্ষে ২ অক্ষরের হতে হবে', 'en': 'Name needs at least 2 letters', 'hi': 'नाम में कम से कम 2 अक्षर'},
  'SENSITIVE': {'bn': 'পাসওয়ার্ড, পিন, কার্ড নম্বর সেভ করা হয় না', 'en': 'Passwords, PINs and card numbers are never saved', 'hi': 'पासवर्ड, पिन, कार्ड नंबर सेव नहीं होते'},
  'MEMORY_LIMIT': {'bn': 'মেমোরি পূর্ণ, কিছু মুছুন বা Premium নিন', 'en': 'Memory full — delete some or upgrade', 'hi': 'मेमोरी भर गई'},
  'QUOTA_EXCEEDED': {'bn': 'এই মাসের AI-মিনিট শেষ', 'en': 'AI minutes finished for this month', 'hi': 'इस महीने के AI मिनट खत्म'},
  'PLAN_EXPIRED': {'bn': 'প্ল্যানের মেয়াদ শেষ', 'en': 'Your plan has expired', 'hi': 'प्लान खत्म हो गया'},
  'NO_SERVER': {'bn': 'সার্ভারের ঠিকানা দিন', 'en': 'Enter the server address', 'hi': 'सर्वर का पता डालें'},
  'NETWORK': {'bn': 'ইন্টারনেট সংযোগ নেই', 'en': 'No internet connection', 'hi': 'इंटरनेट नहीं है'},
};

String tr(String lang, String key, {Map<String, String> vars = const {}}) {
  var s = _strings[key]?[lang] ?? _strings[key]?['en'] ?? key;
  vars.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

String trError(String lang, String code, String fallback) =>
    _errors[code]?[lang] ?? _errors[code]?['en'] ?? fallback;
