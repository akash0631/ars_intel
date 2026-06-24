import os, snowflake.connector
from cryptography.hazmat.primitives import serialization
with open(os.path.expanduser('~/.snowflake/akashv2kart_rsa.p8'),'rb') as f:
    k = serialization.load_pem_private_key(f.read(), password=None)
c = snowflake.connector.connect(account='iafphkw-hh80816', user='akashv2kart', warehouse='ALLOC_WH', database='V2RETAIL', private_key=k.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption()))
cur = c.cursor()
cur.execute('SHOW TABLES IN SCHEMA V2RETAIL.ARS_BRONZE')
rows = cur.fetchall()
print('TOTAL:', len(rows))
for r in rows:
    print(r[1], '|', r[3])
