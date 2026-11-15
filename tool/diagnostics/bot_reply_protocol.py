#!/usr/bin/env python3
"""Synthetic Bot protocol probe. Never reads saved accounts or chat history.

Example (uses an API key already set in your own shell):
  python tool/diagnostics/bot_reply_protocol.py --base-url https://api.example/v1 \
    --model MODEL --api-key-env PROBE_API_KEY --protocol chat --turns 24

Two independent histories use identical synthetic prompts: upstream-style only,
then the same prompt plus BaoCode's reminder each turn. Requests are billable.
Only lengths/tag counts/HTTP status are printed, never response text or keys.
This measures compliance at the API boundary, not phone rendering, and cannot
prove whether a provider stripped tags or its model never generated them.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TAGS = re.compile(r'<(bot_say|bot_narrate|bot_show_chat)(?:\s+[a-z]+="[^"]*")*\s*>([\s\S]*?)(?:</\1\s*>|$)')


def counts(text):
    tags = list(TAGS.finditer(text))
    return {'characters': len(text), 'public_parts': len(tags),
            'say_parts': sum(m[1] == 'bot_say' and bool(m[2].strip()) for m in tags)}


def constants():
    source = (Path(__file__).resolve().parents[2] / 'lib/bots/bot_prompt.dart').read_text()
    style = re.search(r"const botChatStyle = '''(.*?)''';", source, re.S)[1]
    definition = re.search(r'const botReplyProtocolReminder =\s*(.*?);', source, re.S)[1]
    reminder = ''.join(re.findall(r"'([^']*)'", definition))
    return style, reminder


def call(args, messages, system, key):
    if args.protocol == 'chat':
        path = '/chat/completions'
        body = {'model': args.model, 'messages': [{'role': 'system', 'content': system}, *messages],
                'stream': False, 'max_tokens': 256}
        headers = {'Authorization': 'Bearer ' + key}
    else:
        path = '/messages'
        body = {'model': args.model, 'system': system, 'messages': messages,
                'stream': False, 'max_tokens': 256}
        headers = {'x-api-key': key, 'anthropic-version': '2023-06-01'}
    headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(args.base_url.rstrip('/') + path,
                                    data=json.dumps(body).encode(), headers=headers)
    # No redirects: never forward credentials to an unexpected destination.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    with urllib.request.build_opener(NoRedirect).open(request, timeout=90) as response:
        result = json.load(response)
    if args.protocol == 'chat':
        text = result['choices'][0]['message'].get('content')
        if not isinstance(text, str):
            raise ValueError('No text content')
        return text
    return ''.join(x['text'] for x in result['content'] if x.get('type') == 'text')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url')
    parser.add_argument('--model')
    parser.add_argument('--api-key-env', default='PROBE_API_KEY')
    parser.add_argument('--protocol', choices=['chat', 'anthropic'], default='chat')
    parser.add_argument('--turns', type=int, default=24)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    style, reminder = constants()
    if args.self_test:
        assert '<bot_say>' in style and '<system-reminder>' in reminder
        assert counts('<bot_say>Hello</bot_say>')['say_parts'] == 1
        assert counts('private<bot_suggest>continue</bot_suggest>')['public_parts'] == 0
        assert counts('<bot_narrate>story</bot_narrate>')['say_parts'] == 0
        print('self-test passed (no network)')
        return 0
    if not args.base_url or not args.model or not 1 <= args.turns <= 100:
        parser.error('provide base URL, model, and 1–100 turns')
    url = urllib.parse.urlparse(args.base_url)
    if url.username or url.password or url.query or url.fragment or url.scheme != 'https':
        parser.error('base URL must be HTTPS without credentials/query/fragment')
    key = os.environ.get(args.api_key_env)
    if not key:
        parser.error('specified API-key environment variable is empty')
    for reinforced in [False, True]:
        history = []
        failures = 0
        for turn in range(args.turns):
            prompt = f'Synthetic protocol check {turn + 1}. Reply to me with only the number {turn + 1}, using the chat message format. This is not a request to work on files or call tools.'
            history.append({'role': 'user', 'content': (reminder + '\n' if reinforced else '') + prompt})
            try:
                reply = call(args, history, style, key)
            except urllib.error.HTTPError as error:
                print(json.dumps({'arm': 'reminder' if reinforced else 'baseline', 'turn': turn + 1, 'http_error': error.code}))
                return 2
            except Exception as error:
                print(json.dumps({'error_type': type(error).__name__}))
                return 2
            metrics = counts(reply)
            failures += metrics['say_parts'] == 0
            print(json.dumps({'arm': 'reminder' if reinforced else 'baseline', 'turn': turn + 1, **metrics}), flush=True)
            history.append({'role': 'assistant', 'content': reply})
        print(json.dumps({'arm': 'reminder' if reinforced else 'baseline', 'turns': args.turns, 'missing_say_turns': failures}), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
