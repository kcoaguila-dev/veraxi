import os

import yaml

env_dict = {}
with open('.env', 'r') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '=' in line:
            key, val = line.split('=', 1)
            val = val.strip(' \'"') # Strip quotes
            if val: # Only include non-empty values
                env_dict[key] = val

with open('env.yaml', 'w') as f:
    yaml.dump(env_dict, f)

os.system('gcloud run deploy veraxi-backend --source . --region us-east4 --allow-unauthenticated --memory 2Gi --cpu 1 --max-instances 10 --env-vars-file=env.yaml')
