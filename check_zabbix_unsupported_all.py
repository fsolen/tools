import requests
import getpass
import csv

def zabbix_api(method, params, auth=None):
    response = requests.post(
        f"{ZABBIX_URL}/api_jsonrpc.php",
        json={
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
            "auth": auth,
        },
        headers={"Content-Type": "application/json"}
    )

    response.raise_for_status()
    data = response.json()

    if "error" in data:
        print(f"\n Zabbix API Error ({method}): {data['error']['message']} - {data['error']['data']}")
        exit(1)

    return data["result"]

def prompt_credentials():
    global ZABBIX_URL
    while True:
        url = input(" Enter Zabbix URL (e.g. http://192.168.1.100/zabbix): ").strip().rstrip('/')
        if url:
            ZABBIX_URL = url
            break
        else:
            print(" Please enter a valid Zabbix URL.")
    user = input(" Username: ").strip()
    password = getpass.getpass(" Password: ").strip()
    return user, password

def print_unsupported(title, entities, export_list):
    if entities:
        for ent in entities:
            export_list.append([title, ent['name'], ent['error']])

def check_templates(auth_token, export_list):
    templates = zabbix_api("template.get", {
        "output": ["templateid", "name"]
    }, auth_token)

    print(f"\n Checking {len(templates)} templates...\n")

    for tpl in templates:
        print(f" Template: {tpl['name']}")

        items = zabbix_api("item.get", {
            "output": ["name", "error"],
            "templateids": tpl["templateid"],
            "filter": {"state": "1"}  # unsupported
        }, auth_token)

        llds = zabbix_api("discoveryrule.get", {
            "output": ["name", "error"],
            "templateids": tpl["templateid"],
            "filter": {"state": "1"}
        }, auth_token)

        print_unsupported("Unsupported Items", items, export_list)
        print_unsupported("Unsupported Discovery Rules", llds, export_list)

def check_hosts(auth_token, export_list):
    hosts = zabbix_api("host.get", {
        "output": ["hostid", "name"],
        "filter": {"status": "0"}  # only monitored hosts
    }, auth_token)

    print(f"\n Checking {len(hosts)} monitored hosts...\n")

    for host in hosts:
        print(f" Host: {host['name']}")

        items = zabbix_api("item.get", {
            "output": ["name", "error"],
            "hostids": host["hostid"],
            "filter": {"state": "1"}
        }, auth_token)

        llds = zabbix_api("discoveryrule.get", {
            "output": ["name", "error"],
            "hostids": host["hostid"],
            "filter": {"state": "1"}
        }, auth_token)

        print_unsupported("Unsupported Items", items, export_list)
        print_unsupported("Unsupported Discovery Rules", llds, export_list)

def export_to_csv(export_list):
    # Define CSV filename
    filename = "zabbix_unsupported_items.csv"

    # Write to CSV
    with open(filename, mode='w', newline='', encoding='utf-8') as file:
        writer = csv.writer(file)
        writer.writerow(["Type", "Name", "Error"])  # header
        writer.writerows(export_list)
    print(f"Exported unsupported items to {filename}")

def main():
    user, password = prompt_credentials()

    print(" Authenticating to Zabbix...")
    auth_token = zabbix_api("user.login", {
        "username": user,
        "password": password
    })

    export_list = []

    check_templates(auth_token, export_list)
    check_hosts(auth_token, export_list)

    export_to_csv(export_list)

    print("\n Full unsupported item check complete.")

if __name__ == "__main__":
    main()
