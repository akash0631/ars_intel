import os, snowflake.connector
from cryptography.hazmat.primitives import serialization
with open(os.path.expanduser('~/.snowflake/akashv2kart_rsa.p8'),'rb') as f:
    k = serialization.load_pem_private_key(f.read(), password=None)
c = snowflake.connector.connect(account='iafphkw-hh80816', user='akashv2kart', warehouse='ALLOC_WH', database='V2RETAIL', private_key=k.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption()))
cur = c.cursor()
for t in ['STORE_PLANT_MASTER', 'MASTER_PRODUCT', 'MASTER_ALC_INPUT_ST_ART', 'ARS_ALLOC_HISTORY', 'ARS_PEND_ALC', 'ARS_ALLOC_MAJCAT_QUEUE', 'ARS_MSA_VAR_ART', 'MASTER_CONT_FAB']:
    print(f'\n=== {t} ===')
    try:
        cur.execute(f"SELECT COLUMN_NAME, DATA_TYPE FROM V2RETAIL.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='ARS_BRONZE' AND TABLE_NAME='{t}' ORDER BY ORDINAL_POSITION")
        for r in cur.fetchall():
            print(r[0], r[1])
    except Exception as e:
        print('ERR:', e)
