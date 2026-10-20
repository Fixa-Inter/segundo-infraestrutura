#!/usr/bin/env python3
"""Sincroniza SecureStrings via stdin do AWS CLI; manifestos so contem ARNs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from env_config import BACKENDS, ConfigError, parse_env, validate
from firebase_config import mobile_firebase

ROOT = Path(__file__).resolve().parents[1]


def aws(*args, payload=None):
    response = subprocess.run(['aws', *args, '--output', 'json', '--no-cli-pager'],
                              input=json.dumps(payload) if payload is not None else None,
                              text=True, capture_output=True)
    if response.returncode:
        import re

        code = re.search(r'\((\w+)\)', response.stderr)
        error_code = code[1] if code else 'FalhaAWS'

        if error_code == 'ParamValidation':
            issues = []

            for line in response.stderr.splitlines():
                match = re.search(
                    r'Invalid (type|length|value|range) for parameter '
                    r'([A-Za-z0-9_.\[\]-]+)(?:,|:)',
                    line,
                )
                if match:
                    issues.append(f'{match[2]}: {match[1]} invalido')

                match = re.search(
                    r'(Missing required|Unknown) parameter in input: '
                    r'"([A-Za-z0-9_]+)"',
                    line,
                )
                if match:
                    issues.append(f'{match[2]}: {match[1]}')

            detail = '; '.join(dict.fromkeys(issues))
            operation = ' '.join(args[:2])

            raise ConfigError(
                f'AWS: {error_code} | {operation} | '
                f'{detail or "campo nao identificado"}'
            )

        raise ConfigError('AWS: ' + error_code)
    return json.loads(response.stdout or '{}')


def private_json(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(content, f, ensure_ascii=False, indent=2)
            f.write('\n')
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def load_all(selection):
    contracts = json.loads((ROOT/'config/backends.json').read_text())
    result = {}
    for api in selection:
        p = ROOT/'env'/f'{api}.env'
        if not p.is_file():
            raise ConfigError(f'env/{api}.env: arquivo ausente')
        p.chmod(0o600)
        try:
            result[api] = validate(api, parse_env(p.read_text(encoding='utf-8-sig')), contracts[api])
            if api == 'mobile':
                _, project, _ = mobile_firebase(result[api], ROOT/'env/firebase.json')
                result[api]['FIREBASE_PROJECT_ID'] = project
        except (ConfigError, UnicodeError, ValueError):
            # Validadores sempre geram erros sem valor; erros externos nao devem vazar entrada.
            exc = sys.exc_info()[1]
            if isinstance(exc, ConfigError):
                raise ConfigError(f'{api}: {exc}') from None
            raise ConfigError(f'{api}: formato invalido') from None
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('backend', choices=(*BACKENDS, 'all'), default='all', nargs='?')
    parser.add_argument('--check', action='store_true', help='Validacao local; nao chama AWS')
    parser.add_argument('--region', default='us-east-1')
    args = parser.parse_args()
    os.umask(0o077)
    configs = load_all(BACKENDS if args.backend == 'all' else [args.backend])
    if args.check:
        for api, values in configs.items():
            print(f'[OK] {api}: {len(values)} variaveis validadas; valores omitidos')
        return
    account = aws('sts', 'get-caller-identity')['Account']
    directory = ROOT/'.states'/account/args.region/'env'
    for api, values in configs.items():
        refs = {}
        versions = {}
        public = {}
        for key, value in sorted(values.items()):
            if api == 'mobile' and key in ('FIREBASE_CREDENTIALS_PATH','FIREBASE_PROJECT_ID'):
                public[key] = value
                continue
            # Preserva maiusculas e underscores para nao colidir FOO_BAR e foo_bar.
            name = f'/fixa/{api}/{key}'
            try:
                current = aws('ssm','get-parameter','--region',args.region,'--name',name,'--with-decryption')['Parameter']
            except ConfigError as exc:
                if str(exc) != 'AWS: ParameterNotFound':
                    raise
                current = None
            if current and current['Value'] == value and current['Type'] == 'SecureString':
                version = current['Version']
            else:
                version = aws('ssm','put-parameter','--region',args.region,'--cli-input-json','file:///dev/stdin',
                              payload={'Name':name,'Value':value,'Type':'SecureString','Tier':'Standard','Overwrite':True})['Version']
            refs[key] = f'arn:aws:ssm:{args.region}:{account}:parameter{name}'
            versions[key] = version
        private_json(directory/f'{api}.public.json', public)
        # public.env contem apenas caminho/project ID nao secretos para o Mobile.
        public_env = directory/f'{api}.public.env'
        public_env.write_text(''.join(f'{k}={v}\n' for k,v in sorted(public.items())))
        public_env.chmod(0o600)
        private_json(directory/f'{api}.secrets.json', refs)
        private_json(directory/f'{api}.versions.json', versions)
        print(f'[OK] {api}: referencias SSM geradas para conta/regiao atuais')

if __name__ == '__main__':
    try:
        main()
    except (ConfigError, OSError) as exc:
        # OSError nao mostra conteudos; somente nomes de arquivos/comandos.
        print(f'[ERRO] {exc}', file=sys.stderr)
        sys.exit(1)
