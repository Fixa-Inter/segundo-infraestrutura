"""Validacao local da credencial; nunca inclui conteudo em mensagens."""
import hashlib
import json
from pathlib import Path
from env_config import ConfigError

CONTAINER_PATH = '/app/secrets/firebase.json'
MAX_BYTES = 128 * 1024


def read_firebase(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        raise ConfigError('env/firebase.json: arquivo regular ausente (symlinks nao aceitos)')
    path.chmod(0o600)
    if path.stat().st_size > MAX_BYTES:
        raise ConfigError('env/firebase.json: excede limite de seguranca de 128 KiB')
    raw = path.read_bytes()
    if len(raw) > MAX_BYTES:
        raise ConfigError('env/firebase.json: excede limite de seguranca de 128 KiB')
    try:
        value = json.loads(raw.decode('utf-8-sig'))
    except (ValueError, UnicodeError):
        raise ConfigError('env/firebase.json: JSON invalido') from None
    if not isinstance(value, dict) or value.get('type') != 'service_account':
        raise ConfigError('env/firebase.json: esperado JSON de conta de servico Firebase')
    for key in ('project_id', 'client_email', 'private_key'):
        if not isinstance(value.get(key), str) or not value[key].strip():
            raise ConfigError(f'env/firebase.json: campo {key} ausente ou invalido')
    if '-----BEGIN PRIVATE KEY-----' not in value['private_key'] or '-----END PRIVATE KEY-----' not in value['private_key']:
        raise ConfigError('env/firebase.json: formato da chave privada invalido')
    return raw, value['project_id'], hashlib.sha256(raw).hexdigest()


def mobile_firebase(values, file_path):
    if values.get('FIREBASE_CREDENTIALS_PATH') != CONTAINER_PATH:
        raise ConfigError(f'FIREBASE_CREDENTIALS_PATH: configure {CONTAINER_PATH}')
    if values.get('FIREBASE_CREDENTIALS_JSON'):
        raise ConfigError('Remova FIREBASE_CREDENTIALS_JSON; esta versao usa env/firebase.json')
    raw, project, digest = read_firebase(file_path)
    if values.get('FIREBASE_PROJECT_ID') and values['FIREBASE_PROJECT_ID'] != project:
        raise ConfigError('FIREBASE_PROJECT_ID: nao corresponde a env/firebase.json')
    return raw, project, digest
