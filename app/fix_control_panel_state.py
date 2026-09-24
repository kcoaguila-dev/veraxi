import re

file_path = '/home/ubuntu/src/ai/veraxi/app/lib/features/control_panel/view_models/control_panel_view_model.dart'
with open(file_path, 'r') as f:
    content = f.read()

# Find all state = ControlPanelState( ... ) 
# and if requiresPayment is not in it, add requiresPayment: state.requiresPayment,

def replace_state(match):
    block = match.group(0)
    if 'requiresPayment:' not in block and 'const ControlPanelState()' not in block:
        # insert before the closing parenthesis
        block = re.sub(r'\s*\);$', ',\n        requiresPayment: state.requiresPayment,\n      );', block)
    return block

# The regex matches state = ControlPanelState( ... );
new_content = re.sub(r'state\s*=\s*ControlPanelState\([^)]+\);', replace_state, content)

with open(file_path, 'w') as f:
    f.write(new_content)

print("Fixed state updates.")
