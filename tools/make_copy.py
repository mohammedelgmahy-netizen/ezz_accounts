#!/usr/bin/env python3
"""ينسخ البرنامج لشركة تانية: بيانات منفصلة (بادئة جداول مختلفة) واسم وأيقونة مختلفين.
usage: make_copy.py SLUG PREFIX "الاسم الكامل" "سطر1" "سطر2" "اسم مختصر" "حروف الأيقونة" "كلمة تحت الأيقونة"
"""
import sys, os, re, shutil, subprocess, json
slug, prefix, full, l1, l2, short, ibig, ismall = sys.argv[1:9]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, slug); os.makedirs(out, exist_ok=True)
s = open(os.path.join(root, "index.html"), encoding="utf-8").read()
s = s.replace("عز الدين للمقاولات العامة والتوريدات", full)
s = s.replace("<b>عز الدين للمقاولات</b><small>العامة والتوريدات</small>", f"<b>{l1}</b><small>{l2}</small>")
s = s.replace("<title>عز الدين للمقاولات</title>", f"<title>{short}</title>")
s = s.replace("ezz-backup-", slug + "-backup-").replace('"ezz-"+', f'"{slug}-"+')
s = s.replace("ezz_", prefix)
assert "عز الدين" not in s, [m.start() for m in re.finditer("عز الدين", s)]
open(os.path.join(out, "index.html"), "w", encoding="utf-8").write(s)
m = json.load(open(os.path.join(root, "manifest.json"), encoding="utf-8"))
m.update(name=full, short_name=short)
json.dump(m, open(os.path.join(out, "manifest.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
shutil.copy(os.path.join(root, "sw.js"), out)
sql = open(os.path.join(root, "schema.sql"), encoding="utf-8").read().replace("ezz_", prefix)
open(os.path.join(out, "schema.sql"), "w", encoding="utf-8").write(sql)
js = """const {chromium}=require('playwright');(async()=>{const b=await chromium.launch();
for(const s of [192,512]){const p=await b.newPage({viewport:{width:s,height:s}});
await p.setContent(`<html><body style="margin:0"><div style="width:${s}px;height:${s}px;background:linear-gradient(135deg,#24527c,#12283f);display:flex;flex-direction:column;align-items:center;justify-content:center;color:#fff;font-family:'FreeSerif','DejaVu Sans',serif;direction:rtl">
<div style="font-size:${s*BIGSIZE}px;font-weight:bold;line-height:1;color:#f2c14e">BIG</div>
<div style="font-size:${s*0.12}px;margin-top:${s*0.04}px">SMALL</div>
<div style="width:${s*0.55}px;height:${s*0.025}px;background:#f2c14e;margin-top:${s*0.05}px;border-radius:4px"></div></div></body></html>`);
await p.screenshot({path:`OUT/icon-${s}.png`});}await b.close();})();"""
js = js.replace("BIGSIZE", "0.42" if len(ibig) <= 2 else "0.3").replace("BIG", ibig).replace("SMALL", ismall).replace("OUT", out)
subprocess.run(["node", "-e", js], check=True)
print("done", out)
