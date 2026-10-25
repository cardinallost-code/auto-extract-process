"""Exact-RJ work naming with read-only external cache and official-page fallback."""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import uuid
import html
from urllib.request import Request, ProxyHandler, build_opener, urlopen
from urllib.error import HTTPError
from urllib.parse import urlparse, urlencode


def plain_text(value):
    return ' '.join(html.unescape(re.sub(r'<[^>]*>', '', value)).split())


def parse_work_page(code, body):
    # Match the canonical identity, never recommendation links or search snippets.
    canonical = re.search(r'<link\b(?=[^>]*\brel=[\"\x27]canonical[\"\x27])[^>]*\bhref=[\"\x27]([^\"\x27]+)', body, re.I)
    if not canonical:
        raise ValueError('官方页面缺少可确认作品身份的 canonical 地址')
    url = urlparse(html.unescape(canonical[1]))
    if url.hostname != 'www.dlsite.com' or not re.search(r'/product_id/' + re.escape(code) + r'\.html$', url.path, re.I):
        raise ValueError('官方页面 RJ 编号不一致，拒绝命名')
    title = re.search(r'<h1\b[^>]*\bid=[\"\x27]work_name[\"\x27][^>]*>(.*?)</h1>', body, re.I | re.S)
    if not title or not plain_text(title[1]):
        raise ValueError('官方页面没有有效作品标题')
    voices = []
    maker = ''
    for row in re.findall(r'<tr\b[^>]*>(.*?)</tr>', body, re.I | re.S):
        heading = re.search(r'<th\b[^>]*>(.*?)</th>', row, re.I | re.S)
        cell = re.search(r'<td\b[^>]*>(.*?)</td>', row, re.I | re.S)
        if not heading or not cell:
            continue
        if plain_text(heading[1]) in ('声優', '声优'):
            voices = [plain_text(a) for a in re.findall(r'<a\b[^>]*>(.*?)</a>', cell[1], re.I | re.S)]
    maker_tag = re.search(r'<span\b[^>]*\bclass=[\"\x27]maker_name[\"\x27][^>]*>(.*?)</span>', body, re.I | re.S)
    if maker_tag:
        maker = plain_text(maker_tag[1])
    return {'rjcode': code, 'work_name': plain_text(title[1]), 'cvs': voices, 'maker_name': maker, 'source_url': canonical[1]}


def parse_product_api(code, payload):
    if not isinstance(payload, list):
        raise ValueError('商品接口返回格式异常')
    if not payload:
        return None
    matches = [item for item in payload if isinstance(item, dict) and item.get('workno') == code]
    if len(matches) != 1:
        raise ValueError('商品接口 RJ 编号不一致或不唯一，拒绝命名')
    product = matches[0]
    title = product.get('work_name')
    if not isinstance(title, str) or not title.strip() or '\ufffd' in title:
        raise ValueError('商品接口标题缺失或损坏')
    creators = product.get('creaters') or {}
    voices = creators.get('voice_by', []) if isinstance(creators, dict) else []
    if not isinstance(voices, list) or any(not isinstance(v, dict) or not isinstance(v.get('name'), str) for v in voices):
        raise ValueError('商品接口声优字段格式错误')
    return {'rjcode': code, 'work_name': title, 'maker_name': product.get('maker_name') or '',
            'cvs': [v['name'] for v in voices]}


def open_online(request, timeout, proxy_url=None):
    if not proxy_url:
        return urlopen(request, timeout=timeout)
    parsed = urlparse(proxy_url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        raise ValueError('代理地址必须是有效的 HTTP 或 HTTPS URL')
    opener = build_opener(ProxyHandler({'http': proxy_url, 'https': proxy_url}))
    return opener.open(request, timeout=timeout)


def query_online(code, timeout=15, locale='zh_cn', proxy_url=None):
    if not re.fullmatch(r'RJ\d{8}', code):
        raise ValueError('在线查询必须使用完整 RJ 号')
    if locale not in ('zh_cn', 'zh_tw', 'ja_jp', 'en_us', 'ko_kr'):
        locale = 'zh_cn'
    # The external renamer uses this endpoint; bonus products can have metadata
    # here even when their public HTML work page returns 404.
    api_url = 'https://www.dlsite.com/maniax/api/=/product.json?' + urlencode({'workno': code, 'locale': locale})
    request = Request(api_url, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        with open_online(request, timeout, proxy_url) as response:
            if urlparse(response.url).hostname != 'www.dlsite.com':
                raise ValueError('商品接口跳转至非官方域名')
            body = response.read(4_000_001)
            if len(body) > 4_000_000:
                raise ValueError('商品接口响应超过大小限制')
            metadata = parse_product_api(code, json.loads(body.decode('utf-8')))
            if metadata:
                metadata['source_url'] = api_url
                return metadata
    except HTTPError as exc:
        if exc.code != 404:
            raise
    # Both official categories are tried; 404 is not replaced with a guessed title.
    for category in ('maniax', 'home'):
        url = 'https://www.dlsite.com/' + category + '/work/=/product_id/' + code + '.html'
        request = Request(url, headers={'User-Agent': 'Mozilla/5.0', 'Cookie': 'adultchecked=1', 'Accept-Language': 'ja'})
        try:
            with open_online(request, timeout, proxy_url) as response:
                if urlparse(response.url).hostname != 'www.dlsite.com':
                    raise ValueError('查询跳转至非官方域名')
                body = response.read(4_000_001)
                if len(body) > 4_000_000:
                    raise ValueError('官方页面超过大小限制')
                return parse_work_page(code, body.decode('utf-8'))
        except HTTPError as exc:
            if exc.code == 404:
                continue
            raise
    raise ValueError('DLsite 官方作品页返回 404，保留 RJ 目录等待核实')


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, path)


def folder_name(code, metadata, settings):
    title = metadata.get('work_name')
    if not isinstance(title, str) or not title.strip() or '\ufffd' in title:
        raise ValueError('标题缺失或包含损坏字符')
    if settings.get('renamer_exclude_square_brackets_in_work_name_flag', False):
        title = re.sub(r'\[[^\]]*\]|【[^】]*】', '', title).strip()
    cvsc = metadata.get('cvs') or []
    if not isinstance(cvsc, list) or not all(isinstance(cv, str) for cv in cvsc):
        raise ValueError('声优字段格式错误')
    delimiter = settings.get('renamer_delimiter', ' ')
    cvs = (settings.get('cv_list_left', '(CV ') + '、'.join(cvsc) +
           settings.get('cv_list_right', ')')) if cvsc else ''
    fields = {'rjcode': code, 'work_name': title, 'cv_list_str': cvs,
              'maker_name': str(metadata.get('maker_name') or '')}
    tokens = settings.get('renamer_template', 'rjcode work_name cv_list_str').split()
    if any(token not in fields for token in tokens):
        raise ValueError('命名模板包含尚未支持的字段')
    # RJ is a stable identity and is always retained at the start.
    name = delimiter.join([code] + [fields[t] for t in tokens if t != 'rjcode' and fields[t]])
    fullwidth = settings.get('renamer_illegal_character_to_full_width_flag', False)
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]',
                  lambda m: chr(ord(m[0]) + 0xFEE0) if fullwidth and ord(m[0]) >= 32 else '_', name)
    name = name.rstrip(' .')
    if len(name.encode('utf-16-le')) // 2 > 240:
        raise ValueError('完整名称超过安全长度，保留原目录等待人工处理')
    return name


def run(result_path, config_path):
    result = read_json(result_path)
    config = read_json(config_path).get('naming', {})
    records = []
    directories = []
    connection = None
    error = None
    settings = {}
    online_cache_path = Path(config_path).resolve().parent / 'work' / 'naming_metadata.json'
    online_cache = {}
    if online_cache_path.exists():
        try:
            online_cache = read_json(online_cache_path)
        except (ValueError, OSError):
            pass
    enabled = config.get('enabled', True)
    if enabled:
        try:
            settings = read_json(config['external_config'])
        except Exception as exc:
            error = str(exc)
        try:
            connection = sqlite3.connect(Path(config['cache_db']).resolve().as_uri() + '?mode=ro', uri=True)
        except (OSError, sqlite3.Error):
            pass
    original_directories = list(dict.fromkeys(result['final_directories']))
    for original in original_directories:
        source = Path(original)
        record = {'old_path': str(source), 'new_path': str(source), 'status': 'pending'}
        try:
            if not enabled:
                record['status'] = 'disabled'
            else:
                if source.is_symlink() or (hasattr(source, 'is_junction') and source.is_junction()):
                    raise ValueError('作品目录为链接')
                match = re.match(r'^(RJ\d{8})(?!\d)', source.name, re.I)
                if not match:
                    record['status'] = 'not_applicable'
                    record['reason'] = '无 RJ 编号，保留已整理的目录名称'
                    directories.append(record['new_path'])
                    records.append(record)
                    result['final_directories'] = directories + original_directories[len(directories):]
                    result['naming_results'] = records
                    write_json(result_path, result)
                    print(json.dumps(record, ensure_ascii=False), flush=True)
                    continue
                if error:
                    raise ValueError(error)
                code = match[1].upper()
                row = None
                if connection:
                    try:
                        row = connection.execute('SELECT metadata FROM workmetadatacache WHERE UPPER(rjcode)=?', (code,)).fetchone()
                    except sqlite3.Error:
                        pass
                metadata = json.loads(row[0]) if row else online_cache.get(code)
                record['metadata_source'] = 'external_cache' if row else 'local_online_cache'
                if not metadata:
                    if not config.get('online_fallback', False):
                        raise ValueError('本地缓存未命中，保留 RJ 目录')
                    metadata = query_online(
                        code,
                        float(config.get('online_timeout_seconds', 15)),
                        settings.get('scraper_locale', 'zh_cn'),
                        config.get('proxy_url'),
                    )
                    online_cache[code] = metadata
                    online_cache_path.parent.mkdir(parents=True, exist_ok=True)
                    write_json(online_cache_path, online_cache)
                    record['metadata_source'] = 'dlsite_online'
                if str(metadata.get('rjcode', '')).upper() != code:
                    raise ValueError('缓存中的 RJ 身份不一致')
                target = source.with_name(folder_name(code, metadata, settings))
                if len(str(target).encode('utf-16-le')) // 2 > 240:
                    raise ValueError('完整路径过长，保留原目录')
                if not source.exists():
                    # The user may have renamed this directory with the external tool.
                    # Accept only its exact metadata-derived name in the same parent.
                    if not target.is_dir() or target.is_symlink() or (hasattr(target, 'is_junction') and target.is_junction()):
                        raise ValueError('作品目录不存在，且未找到元数据对应的完整名称目录')
                    record.update(new_path=str(target), status='recognized_external_rename')
                elif not source.is_dir():
                    raise ValueError('作品路径不是目录')
                elif target == source:
                    record['status'] = 'unchanged'
                else:
                    if target.exists():
                        raise ValueError('目标目录已存在，禁止覆盖或合并')
                    source.rename(target)
                    record.update(new_path=str(target), status='renamed')
        except Exception as exc:
            record['reason'] = str(exc)
        directories.append(record['new_path'])
        records.append(record)
        # Persist every successful rename immediately for retry and recovery.
        result['final_directories'] = directories + original_directories[len(directories):]
        result['naming_results'] = records
        write_json(result_path, result)
        print(json.dumps(record, ensure_ascii=False), flush=True)
    if connection:
        connection.close()
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--result', required=True)
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    run(args.result, args.config)
