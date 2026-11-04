# Registers a device UDID in the ITalk team so automatic signing includes it
# in the development profile. Run: uv run --with pyjwt --with cryptography python3 -I register-device.py <UDID>
import jwt, time, json, sys, urllib.request
K='25KYCN22QD'; I='69a6de85-f7cc-47e3-e053-5b8c7c11a4d1'
key=open(f'/Users/ms/.appstoreconnect/private_keys/AuthKey_{K}.p8').read()
tok=jwt.encode({'iss':I,'iat':int(time.time()),'exp':int(time.time())+1200,'aud':'appstoreconnect-v1'},key,algorithm='ES256',headers={'kid':K})
def call(m,path,body=None):
    r=urllib.request.Request('https://api.appstoreconnect.apple.com'+path,method=m,data=json.dumps(body).encode() if body else None,headers={'Authorization':'Bearer '+tok,'Content-Type':'application/json'})
    try: return json.load(urllib.request.urlopen(r))
    except urllib.error.HTTPError as e: print(e.code, e.read().decode()[:400]); sys.exit(1)
udid=sys.argv[1]
devs=call('GET','/v1/devices?limit=200')['data']
hit=[d for d in devs if d['attributes']['udid'].lower()==udid.lower()]
if hit: print('registered:', hit[0]['attributes']['name'], hit[0]['attributes']['status'])
else:
    d=call('POST','/v1/devices',{'data':{'type':'devices','attributes':{'name':'iPhone MS 15 Pro','udid':udid,'platform':'IOS'}}})
    print('added', d['data']['id'])
