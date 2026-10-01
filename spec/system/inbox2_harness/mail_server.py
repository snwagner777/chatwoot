"""Disposable loopback-only IMAP fixture. Never connects to a real provider."""
import json
import os
import re
import socketserver
import threading
from pathlib import Path

root = Path(os.environ['INBOX2_QA_TMP_DIR'])
state = {'INBOX': {i * 3 + j + 1: f'synthetic-{i}-{j}@example.test' for i in range(2) for j in range(3)}, 'Trash': {}, 'Junk': {}}
lock = threading.Lock()


def save():
    (root / 'provider-state.json').write_text(json.dumps(state))


class Imap(socketserver.StreamRequestHandler):
    def line(self, text):
        self.wfile.write((text + '\r\n').encode())
        self.wfile.flush()

    def handle(self):
        selected = 'INBOX'
        self.line('* OK Synthetic IMAP fixture')
        while raw := self.rfile.readline():
            parts = raw.decode().strip().split(' ', 2)
            if len(parts) < 2:
                break
            tag, command = parts[:2]
            args = parts[2] if len(parts) > 2 else ''
            with lock:
                if command == 'CAPABILITY':
                    self.line('* CAPABILITY IMAP4rev1 MOVE UIDPLUS AUTH=PLAIN')
                elif command == 'LOGIN':
                    if args != 'synthetic synthetic-only' and args != '"synthetic" "synthetic-only"':
                        self.line(tag + ' NO Synthetic credentials required')
                        continue
                elif command == 'AUTHENTICATE':
                    self.line('+ ')
                    self.rfile.readline()
                elif command == 'LIST':
                    for name in state:
                        flag = '\\' + name if name != 'INBOX' else '\\HasNoChildren'
                        self.line(f'* LIST ({flag}) "/" "{name}"')
                elif command in ('SELECT', 'EXAMINE'):
                    selected = args.strip('"')
                    self.line('* FLAGS (\\Seen)')
                    self.line(f'* {len(state[selected])} EXISTS')
                    self.line('* OK [UIDVALIDITY 7] stable synthetic mailbox')
                elif command == 'UID':
                    verb, rest = args.split(' ', 1)
                    if verb == 'SEARCH':
                        source_id = rest.split(' ', 2)[-1].strip('"')
                        found = [str(uid) for uid, source in state[selected].items() if source == source_id]
                        self.line('* SEARCH' + (' ' + ' '.join(found) if found else ''))
                    elif verb == 'FETCH':
                        uid = int(rest.split(' ')[0])
                        if uid in state[selected]:
                            header = f'Message-ID: <{state[selected][uid]}>\r\n\r\n'
                            self.line(f'* 1 FETCH (UID {uid} BODY[HEADER.FIELDS (MESSAGE-ID)] {{{len(header.encode())}}}')
                            self.wfile.write(header.encode() + b')\r\n')
                            self.wfile.flush()
                    elif verb == 'MOVE':
                        uid_text, destination = rest.split(' ', 1)
                        uid = int(uid_text)
                        destination = destination.strip('"')
                        if uid not in state[selected] or destination not in ('Trash', 'Junk'):
                            self.line(tag + ' NO Invalid synthetic move')
                            continue
                        state[destination][uid] = state[selected].pop(uid)
                        save()
                    else:
                        self.line(tag + ' BAD Unsupported fixture UID command')
                        continue
                elif command == 'LOGOUT':
                    self.line('* BYE Synthetic logout')
                    self.line(tag + ' OK Logout complete')
                    break
                elif command != 'NOOP':
                    self.line(tag + ' BAD Unsupported fixture command')
                    continue
                self.line(tag + ' OK completed')


class Smtp(socketserver.StreamRequestHandler):
    def line(self, text):
        self.wfile.write((text + '\r\n').encode())
        self.wfile.flush()

    def handle(self):
        envelope = {}
        self.line('220 synthetic.example.test ESMTP fixture')
        while raw := self.rfile.readline():
            line = raw.decode().strip()
            command = line.split(' ', 1)[0].upper()
            if command in ('EHLO', 'HELO'):
                self.line('250-synthetic.example.test')
                self.line('250-AUTH LOGIN PLAIN')
                self.line('250 SIZE 1048576')
            elif command == 'AUTH':
                if 'LOGIN' in line:
                    self.line('334 VXNlcm5hbWU6')
                    self.rfile.readline()
                    self.line('334 UGFzc3dvcmQ6')
                    self.rfile.readline()
                elif len(line.split(' ')) < 3:
                    self.line('334 ')
                    self.rfile.readline()
                self.line('235 Authentication successful for synthetic fixture')
            elif command == 'MAIL':
                envelope['from'] = line
                self.line('250 Sender accepted')
            elif command == 'RCPT':
                envelope['to'] = line
                self.line('250 Recipient accepted')
            elif command == 'DATA':
                self.line('354 End with a dot')
                chunks = []
                while (data := self.rfile.readline()) not in (b'.\r\n', b''):
                    chunks.append(data.decode())
                envelope['body'] = ''.join(chunks)
                (root / 'smtp-state.json').write_text(json.dumps(envelope))
                self.line('250 Synthetic message captured')
            elif command == 'QUIT':
                self.line('221 Goodbye')
                break
            else:
                self.line('250 OK')


if __name__ == '__main__':
    assert os.environ['INBOX2_SYNTHETIC_QA'] == '1'
    save()
    smtp = socketserver.ThreadingTCPServer(('127.0.0.1', 1025), Smtp)
    threading.Thread(target=smtp.serve_forever, daemon=True).start()
    with socketserver.ThreadingTCPServer(('127.0.0.1', 1143), Imap) as server:
        server.serve_forever()
