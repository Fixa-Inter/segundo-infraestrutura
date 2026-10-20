"""Parser .env sem execucao/interpolacao. Nunca inclui valores em erros."""
import json
import re
from urllib.parse import urlsplit

BACKENDS = ('mobile', 'web', 'nosql', 'ia')

class ConfigError(ValueError):
    pass


def parse_env(text):
    lines = text.splitlines()
    result = {}
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line or line.startswith('#'):
            continue
        m = re.fullmatch(r'(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)', line)
        if not m:
            raise ConfigError(f'Linha {i}: atribuicao invalida')
        name, raw = m.groups()
        if name in result:
            raise ConfigError(f'{name}: variavel duplicada')
        if raw.startswith(('"', "'")):
            quote = raw[0]
            body = raw[1:]
            # Aspas fecham apenas sem escape, inclusive JSON multilinha.
            while True:
                closing = None
                for n, ch in enumerate(body):
                    if ch == quote and len(body[:n]) - len(body[:n].rstrip('\\')) & 1 == 0:
                        closing = n
                        break
                if closing is not None:
                    suffix = body[closing+1:].strip()
                    if suffix and not suffix.startswith('#'):
                        raise ConfigError(f'{name}: conteudo apos aspas')
                    value = body[:closing]
                    if quote == '"':
                        value = re.sub(r'\\([nrt"\\])', lambda m: {'n':'\n','r':'\r','t':'\t','"':'"','\\':'\\'}[m[1]], value)
                    break
                if i >= len(lines):
                    raise ConfigError(f'{name}: aspas nao fechadas')
                body += '\n' + lines[i]
                i += 1
        elif raw.startswith(('{', '[')):
            # JSON sem aspas externas, inclusive com varias linhas.
            while True:
                try:
                    obj = json.loads(raw)
                    value = json.dumps(obj, ensure_ascii=False, separators=(',', ':'))
                    break
                except json.JSONDecodeError:
                    if i >= len(lines):
                        raise ConfigError(f'{name}: JSON invalido') from None
                    raw += '\n' + lines[i]
                    i += 1
        else:
            value = re.split(r'\s+#', raw, maxsplit=1)[0].rstrip()
        if '\x00' in value:
            raise ConfigError(f'{name}: byte nulo nao permitido')
        if '${' in value or '$(' in value or '`' in value:
            raise ConfigError(f'{name}: expansao shell nao suportada; forneca valor literal')
        result[name] = value
    if not result:
        raise ConfigError('Arquivo sem variaveis')
    return result


def validate(api, values, contract):
    # Opcionais vazias nao vao ao SSM; as APIs usam seus valores padrao.
    values = {key: value for key, value in values.items() if value.strip()}
    for key in contract.get('booleans', []):
        if key in values:
            normalized = values[key].strip().lower()
            boolean = {'true': 'true', 'false': 'false', '1': 'true', '0': 'false'}
            if normalized not in boolean:
                raise ConfigError(f'{key}: use true ou false')
            values[key] = boolean[normalized]
    for source, target in contract.get('aliases', {}).items():
        if source in values:
            if target in values and values[target] != values[source]:
                raise ConfigError(f'{source}/{target}: aliases conflitantes')
            values[target] = values[source]
            if not contract.get('preserve_aliases', False):
                del values[source]
    for key in contract['required']:
        if not values.get(key, '').strip():
            raise ConfigError(f'{key}: obrigatoria ausente ou vazia')
    for key in contract.get('positive_integers', []):
        if key in values and (not values[key].isdigit() or int(values[key]) <= 0):
            raise ConfigError(f'{key}: inteiro positivo esperado')
    for key in contract.get('nonnegative_integers', []):
        if key in values and not values[key].isdigit():
            raise ConfigError(f'{key}: inteiro nao negativo esperado')
    for key in contract.get('emails', []):
        if key in values:
            from email.utils import parseaddr
            address = parseaddr(values[key])[1]
            if not re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', address):
                raise ConfigError(f'{key}: endereco de email invalido')
    if api == 'ia' and values.get('LANGSMITH_TRACING') == 'true' and not values.get('LANGSMITH_API_KEY', '').strip():
        raise ConfigError('LANGSMITH_API_KEY: obrigatoria quando LANGSMITH_TRACING=true')
    if api == 'web' and values.get('MAIL_SMTP_STARTTLS_REQUIRED') == 'true' and values.get('MAIL_SMTP_STARTTLS') != 'true':
        raise ConfigError('MAIL_SMTP_STARTTLS: deve ser true quando STARTTLS e obrigatorio')
    for key, value in list(values.items()):
        if not value:
            # SSM nao aceita strings vazias; opcionais vazias ficam ausentes.
            del values[key]
            continue
        if len(value.encode('utf-8')) > 4096:
            # JSON valido pode ser compactado sem alterar seu significado.
            if key.endswith('_JSON'):
                try:
                    value = json.dumps(json.loads(value), ensure_ascii=False, separators=(',', ':'))
                    values[key] = value
                except json.JSONDecodeError:
                    raise ConfigError(f'{key}: JSON invalido') from None
            if len(value.encode('utf-8')) > 4096:
                raise ConfigError(f'{key}: excede 4096 bytes do SSM Standard; nenhum upgrade pago automatico')
        if key in ('PORT', 'SERVER_PORT') and value != '8080' and api != 'ia':
            raise ConfigError(f'{key}: deve ser 8080 para corresponder ao Target Group')
        if key.endswith('_PORT') or key == 'PORT':
            if not value.isdigit() or not 1 <= int(value) <= 65535:
                raise ConfigError(f'{key}: porta invalida')
        if key.startswith('OBSERVABILITY_'):
            try:
                import math
                n = float(value)
                if not math.isfinite(n) or n < 0:
                    raise ValueError()
            except ValueError:
                raise ConfigError(f'{key}: numero nao negativo esperado') from None
        if key == 'JWT_SECRET' and api != 'web' and len(value.encode()) < 32:
            raise ConfigError(f'{key}: necessario ao menos 32 bytes para HMAC SHA256')
        if key == 'SECURITY_JWT_SECRET' or (api == 'web' and key == 'JWT_SECRET'):
            import base64
            import binascii
            try:
                if len(base64.b64decode(value, validate=True)) < 32:
                    raise ValueError()
            except (ValueError, binascii.Error):
                raise ConfigError(f'{key}: Base64 valido com ao menos 32 bytes decodificados esperado') from None
        if key == 'SECURITY_JWT_EXPIRATIONSECONDS' and (not value.isdigit() or int(value) <= 0):
            raise ConfigError(f'{key}: inteiro positivo esperado')
        if key.endswith(('_URL', '_URI')) or key.startswith('DATABASE_URL_'):
            try:
                parsed = urlsplit(value.removeprefix('jdbc:'))
                host = parsed.hostname
                port = parsed.port
            except ValueError:
                raise ConfigError(f'{key}: URL invalida') from None
            if port is not None and not 1 <= port <= 65535:
                raise ConfigError(f'{key}: porta da URL invalida')
            if not parsed.scheme or not host:
                raise ConfigError(f'{key}: URL sem esquema/host valido')
            if host.lower() in ('localhost', '127.0.0.1', '0.0.0.0', '::1', 'host.docker.internal'):
                raise ConfigError(f'{key}: hostname local nao acessa servico externo no Fargate')
        if key.endswith('_HOST') and value.lower() in ('localhost', '127.0.0.1', '::1', 'host.docker.internal'):
            raise ConfigError(f'{key}: host local invalido no Fargate')
    if api == 'mobile':
        if values.get('FIREBASE_CREDENTIALS_PATH') != '/app/secrets/firebase.json':
            raise ConfigError('FIREBASE_CREDENTIALS_PATH: configure /app/secrets/firebase.json')
        if values.get('FIREBASE_CREDENTIALS_JSON'):
            raise ConfigError('Remova FIREBASE_CREDENTIALS_JSON; use env/firebase.json')
        for key in values:
            if key.startswith('FIREBASE_S3_') or key == 'FIREBASE_CREDENTIALS_SHA256':
                raise ConfigError(f'{key}: reservado ao upload automatizado; remova do .env')
    for key in contract.get('required', []):
        if key.endswith('_URL') or key.startswith('DATABASE_URL_'):
            if key not in values:
                raise ConfigError(f'{key}: obrigatoria ausente')
    for key, schemes in contract.get('url_schemes', {}).items():
        if key in values and not any(values[key].startswith(s + '://') for s in schemes):
            raise ConfigError(f'{key}: esquema de URL incompativel com a aplicacao')
    return values
