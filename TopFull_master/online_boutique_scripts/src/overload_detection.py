from fetch_istio import *
from admission_controller import kubeAPI
from resource_collector import *
from metric_collector import Collector

import json
import logging
import os
import random
import re
import signal
import subprocess
import threading

global_config_path = os.path.expanduser("~/TopFullExt/TopFull_master/online_boutique_scripts/src/global_config.json")
with open(global_config_path, "r") as f:
    global_config = json.load(f)
global_config = {
    k: os.path.expandvars(os.path.expanduser(v)) if isinstance(v, str) else v
    for k, v in global_config.items()
}


"""
CPU quota in this experiment is fixed to 200mi.
Dynamic quota probing is not developed yet
"""
cpu_quota = 200

log = logging.getLogger(__name__)

proxy_rate_dir = global_config["proxy_dir"]
_proxy_lock = threading.Lock()

# Higher priority has larger values
# Online Boutique
business_priority = {
    "postcheckout": 0,
    "getcart": 0,
    "postcart": 0,
    "getproduct": 0,
    "emptycart": 0
}

# Train Ticket
# business_priority = {
#     'high_speed_ticket': 0,
#     'normal_speed_ticket': 0,
#     'query_cheapest': 0,
#     'query_min_station': 0,
#     'query_quickest': 0,
#     'query_order': 0,
#     'query_order_other': 0,
#     'query_route': 0,
#     'query_food': 0,
#     'enter_station': 0,
#     'preserve_normal': 0,
#     'query_contact': 0,
#     'query_payment': 0
# }


def _proxy_pids_for_sigusr1() -> list[int]:
    """PIDs of the real proxy binary only.

    ``pgrep -f proxy_online_boutique`` incorrectly matches the tmux/shell one-liner that
    contains ``go build ... proxy_online_boutique.go``; signalling that parent kills the proxy.
    """
    try:
        raw = subprocess.check_output(
            ["pgrep", "-x", "proxy_online_boutique"],
            stderr=subprocess.DEVNULL,
        )
        pids = [int(p) for p in raw.decode().strip().splitlines() if p.strip()]
        if pids:
            return pids
    except (subprocess.CalledProcessError, ValueError):
        pass
    try:
        out = subprocess.check_output(
            ["ss", "-lntp"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        for line in out.splitlines():
            if ":8090" not in line:
                continue
            m = re.search(r"pid=(\d+)", line)
            if m:
                return [int(m.group(1))]
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        pass
    return []


def apply_threshold_proxy(apis, test=False):
    with _proxy_lock:
        total = 0
        for api in apis:
            if api['threshold'] <= 10:
                api['threshold'] = 10
            with open(os.path.join(proxy_rate_dir, api['name']), 'w') as f:
                f.write(str(api['threshold']))
            print(f"{api['name']}: {api['threshold']}")
            total += api['threshold']

        if test:
            return

        pids = _proxy_pids_for_sigusr1()
        if not pids:
            log.warning("apply_threshold_proxy: no proxy process found, skip reload")
            return

        for pid in pids:
            try:
                os.kill(pid, signal.SIGUSR1)
            except OSError as exc:
                log.warning("apply_threshold_proxy: failed to signal pid %d: %s", pid, exc)


class Detector:
    """
    Initiate detector
    Parameters
    - config: filepath of configuration file, which contains microservices information

    1) Get all services to monitor
    2) Get execution path of APIs
    3) Initialize kubernetes client
    """
    def __init__(self, config=global_config["microservice_configuration"]):
        self.kube = kubeAPI()
        
        rps = self.current_rps()

        self.event = threading.Event()
        t = threading.Thread(target=run, args=(self.event,))
        t.start()
        self.tid = t

        with open(config, "r") as f:
            data = json.load(f)
        self.services = {}
        for svc in data['data']['services']:
            self.services[svc] = {
                'namespace': 'default',
                'cpu': 1000,
                'apis': []
            }

        self.apis = {}
        for api in data['data']['api']:
            self.apis[api['name']] = {
                'method': api['method'],
                'url': api['url'],
                'execution_path': api['execution_path'],
                'threshold': rps.get(api['name'], 10000),
                'name': api['name']
            }

        for svc in list(self.services.keys()):
            for api in list(self.apis.keys()):
                if svc in self.apis[api]['execution_path']:
                    self.services[svc]['apis'].append(api)

        # Experimental Setup, it should match CPU quota unit in yaml files of benchmark applications
        # Online Boutique
        self.services['cartservice']['cpu'] = 1000
        self.services['currencyservice']['cpu'] = 1000
        self.services['frontend']['cpu'] = 1000
        self.services['adservice']['cpu'] = 1000
        self.services['productcatalogservice']['cpu'] = 500
        self.services['checkoutservice']['cpu'] = 1000
        self.services['recommendationservice']['cpu'] = 2000

        # Train Ticket
        # self.services['ts-order-service']['cpu'] = 500
        # self.services['ts-station-service']['cpu'] = 500
        # self.services['ts-order-other-service']['cpu'] = 500
        # self.services['ts-travel-service']['cpu'] = 1000
        # self.services['ts-travel2-service']['cpu'] = 500
        # self.services['ts-contacts-service']['cpu'] = 500
        # self.services['ts-food-service']['cpu'] = 500
        # self.services['ts-inside-payment-service']['cpu'] = 500
        # self.services['ts-food-map-service']['cpu'] = 1000

        return
    
    """
    Find overloaded services among the registered services according to 
    CPU usage and CPU quota for each services.
    If CPU usage per a pod > CPU quota  * alpha, it is overloaded

    Return: List of overloaded service
    """
    def detect(self, alpha=0.9, fail_ratio_threshold=None):
        cpu_overloaded = []
        net_degraded = []

        # Signal 1: CPU overload (original)
        resources = self.get_cpu_util_v2(list(self.services.keys()))
        print(resources)
        for svc in list(resources.keys()):
            usage = resources[svc]
            quota = self.services[svc]['cpu']
            if svc == "productcatalogservice" or svc == "cartservice":
                target = 0.95
            else:
                target = alpha
            if usage > quota * target:
                cpu_overloaded.append(svc)

        # Signal 2 (opt-in): high fail ratio per API → mark services on path
        self._last_fail_ratios = {}
        if fail_ratio_threshold is not None:
            try:
                _c = Collector(code=global_config["microservice_code"])
                metrics = _c.query()
                for api_name, api_info in self.apis.items():
                    vals = metrics.get(api_name)
                    if vals is None:
                        continue
                    rps, fail = float(vals[0]), float(vals[1])
                    fr = fail / rps if rps > 1.0 else 0.0
                    self._last_fail_ratios[api_name] = fr
                    if rps > 1.0 and fr > fail_ratio_threshold:
                        for svc in api_info['execution_path']:
                            if svc not in net_degraded:
                                net_degraded.append(svc)
            except Exception as e:
                print(f"[detect] fail-ratio probe error: {e}")

        # Classify fault type
        has_cpu = len(cpu_overloaded) > 0
        has_net = len(net_degraded) > 0
        if has_cpu and has_net:
            self.last_fault_type = "both"
        elif has_cpu:
            self.last_fault_type = "cpu"
        elif has_net:
            self.last_fault_type = "network"
        else:
            self.last_fault_type = "none"

        result = list(set(cpu_overloaded + net_degraded))
        print(f"[detect] fault_type={self.last_fault_type}  services={result}")
        return result
    
    """
    Find APIs which use the overloaded services
    """
    def clustering(self, services):
        result = []
        for svc in services:
            result += self.services[svc]['apis']

        target_apis = list(set(result))
        ret = []
        rps = self.current_rps()
        # print(rps)
        for api in target_apis:
            if api == "frontend":
                continue
            if rps.get(api, 0) > 0:
                ret.append(api) 
        return ret
    
    """
    Set priority to target APIs, which pass through overloaded services
    """
    def set_priority(self, apis, services):
        result = []
        if len(services) == 0:
            for api in apis:
                result.append((api, 0, business_priority[api]))
        else:
            for api in apis:
                tmp_list = [100]
                for service in self.apis[api]['execution_path']:
                    if service in services:
                        tmp_list.append(len(self.services[service]['apis']))
                result.append((api, min(tmp_list), business_priority[api]))
        return result
    
    """
    Get CPU utilization of each pod with 'kubectl top pod' command
    """
    def get_cpu_util(self, targets):
        output = str(subprocess.check_output('kubectl top pod', shell=True), 'utf-8')
        output = output.split("\n")
        result = {}
        for svc in list(self.services.keys()):
            result[svc] = {'cpu': 0, 'replicas': 0}
        for out in output:
            out = out.split()
            if len(out) != 3:
                continue
            if out[0] == 'NAME':
                continue
            
            name = out[0].split('-')[0]
            cpu = int(out[1][:-1])
            if name in targets:
                if cpu < 20:
                    continue
                if name in result:
                    result[name]['cpu'] += cpu
                    result[name]['replicas'] += 1

        
        for key in list(result.keys()):
            if result[key]['replicas'] > 0:
                result[key]['cpu'] /= result[key]['replicas']
        return result
    

    def get_cpu_util_v2(self, targets):
        result = {}
        for service in targets:
            try:
                result[service] = cpu_util[service]
            except:
                result[service] = 0
        return result
    

    """
    Apply action from RL
    """
    def apply(self, action, target_apis, overloaded_services, test=False):
        overloaded_services_tmp = self.detect(0.9)
        priority = self.set_priority(target_apis, overloaded_services_tmp)
        if len(priority) == 0:
            return
        priority.sort(key=lambda x: x[1]*1000 + x[2])

        if action < 0:
            min_val = priority[0][1]
            target = [priority[0][0]]
            result = [self.apis[priority[0][0]]]

            i = 1
            while i <= len(priority)-1:
                if min_val == priority[i][1] and priority[0][2] == priority[i][2]:
                    target.append(priority[i][0])
                    result.append(self.apis[priority[i][0]])
                    i += 1
                else:
                    break
            
            # Assign action to top-priority APIs
            action *= -1
            leftover = action
            while leftover > 0 and len(target) > 0:
                tmp = leftover / len(target)
                leftover = tmp * len(target)
                remove = []
                for api in target:
                    if self.apis[api]['threshold'] >= tmp:
                        self.apis[api]['threshold'] -= tmp
                        leftover -= tmp
                    else:
                        leftover -= self.apis[api]['threshold']
                        self.apis[api]['threshold'] = 0
                        remove.append(api)
                for api in remove:
                    target.remove(api)
            
            # Assign leftover action to other APIs
            while leftover > 0 and i <= len(priority)-1:
                targetAPI = priority[i][0]
                if self.apis[targetAPI]['threshold'] >= leftover:
                    self.apis[targetAPI]['threshold'] -= leftover
                    leftover = 0
                    result.append(self.apis[targetAPI])
                    break
                else:
                    leftover -= self.apis[targetAPI]['threshold']
                    self.apis[targetAPI]['threshold'] = 0
                    result.append(self.apis[targetAPI])
                    i += 1

            if leftover > 0:
                print(f"Wrong action, leftover: {leftover}")
            apply_threshold_proxy(result,test)

        elif action > 0:
            priority.reverse()
            max_val = priority[0][1]
            target = [priority[0][0]]
            result = [self.apis[priority[0][0]]]

            i = 1
            while i <= len(priority)-1:
                if max_val == priority[i][1] and priority[0][2] == priority[i][2]:
                    target.append(priority[i][0])
                    result.append(self.apis[priority[i][0]])
                    i += 1
                else:
                    break
            
            rps = self.current_rps()
            leftover = action
            margin = 1.1
            while leftover > 0 and len(target) > 0:
                tmp = leftover / len(target)
                leftover = tmp * len(target)
                remove = []
                for api in target:
                    if self.apis[api]['threshold'] + tmp <= rps.get(api, 0) * margin:
                        self.apis[api]['threshold'] += tmp
                        leftover -= tmp
                    else:
                        apply = rps.get(api, 0)*margin - self.apis[api]['threshold']
                        self.apis[api]['threshold'] = rps.get(api, 0) * margin
                        leftover -= apply
                        remove.append(api)
                for api in remove:
                    target.remove(api)
            
            while leftover > 0 and i <= len(priority)-1:
                targetAPI = priority[i][0]
                if self.apis[targetAPI]['threshold'] + leftover <= rps.get(targetAPI, 0) * margin:
                    self.apis[targetAPI]['threshold'] += leftover
                    leftover = 0
                    result.append(self.apis[targetAPI])
                    break
                else:
                    apply = rps.get(targetAPI, 0)*margin - self.apis[targetAPI]['threshold']
                    self.apis[targetAPI]['threshold'] = rps.get(targetAPI, 0)*margin
                    leftover -= apply
                    result.append(self.apis[targetAPI])
                    i += 1
            if leftover > 0:
                print(f"Wrong action, leftover: {leftover}")


            apply_threshold_proxy(result)


    def apply_v2(self, action, target_apis, overloaded_services, test=False):
        overloaded_services_tmp = self.detect(0.8)
        priority = self.set_priority(target_apis, overloaded_services_tmp)
        if len(priority) == 0:
            return
        priority.sort(key=lambda x: x[1]*1000 + x[2])
        print(priority)
        if action < 0:
            target = [priority[0][0]]
            min_val = priority[0][1]
            i = 1
            while i <= len(priority)-1:
                if min_val == priority[i][0] and priority[0][2] == priority[i][2]:
                    target.append(priority[i][0])
                    i += 1
                else:
                    break
        else:
            priority.reverse()
            target = [priority[0][0]]
            min_val = priority[0][1]
            i = 1
            while i <= len(priority)-1:
                if min_val == priority[i][0] and priority[0][2] == priority[i][2]:
                    target.append(priority[i][0])
                    i += 1
                else:
                    break
            priority.reverse()
        
        total_rps = 0
        for api in target:
            total_rps += self.apis[api]['threshold']
        action = action * total_rps

        if action < 0:
            min_val = priority[0][1]
            target = [priority[0][0]]
            result = [self.apis[priority[0][0]]]

            i = 1
            while i <= len(priority)-1:
                if min_val == priority[i][1] and priority[0][2] == priority[i][2]:
                    target.append(priority[i][0])
                    result.append(self.apis[priority[i][0]])
                    i += 1
                else:
                    break
            
            # Assign action to top-priority APIs
            action *= -1
            leftover = action
            while leftover > 0 and len(target) > 0:
                tmp = leftover / len(target)
                leftover = tmp * len(target)
                remove = []
                for api in target:
                    if self.apis[api]['threshold'] >= tmp:
                        self.apis[api]['threshold'] -= tmp
                        leftover -= tmp
                    else:
                        leftover -= self.apis[api]['threshold']
                        self.apis[api]['threshold'] = 0
                        remove.append(api)
                for api in remove:
                    target.remove(api)
            
            # Assign leftover action to other APIs
            while leftover > 0 and i <= len(priority)-1:
                targetAPI = priority[i][0]
                if self.apis[targetAPI]['threshold'] >= leftover:
                    self.apis[targetAPI]['threshold'] -= leftover
                    leftover = 0
                    result.append(self.apis[targetAPI])
                    break
                else:
                    leftover -= self.apis[targetAPI]['threshold']
                    self.apis[targetAPI]['threshold'] = 0
                    result.append(self.apis[targetAPI])
                    i += 1

            if leftover > 0:
                print(f"Wrong action, leftover: {leftover}")
            apply_threshold_proxy(result,test)

        elif action > 0:
            priority.reverse()
            max_val = priority[0][1]
            target = [priority[0][0]]
            result = [self.apis[priority[0][0]]]

            i = 1
            while i <= len(priority)-1:
                if max_val == priority[i][1] and priority[0][2] == priority[i][2]:
                    target.append(priority[i][0])
                    result.append(self.apis[priority[i][0]])
                    i += 1
                else:
                    break
            
            rps = self.current_rps()
            leftover = action
            margin = 1.1
            while leftover > 0 and len(target) > 0:
                tmp = leftover / len(target)
                leftover = tmp * len(target)
                remove = []
                for api in target:
                    if self.apis[api]['threshold'] + tmp <= rps.get(api, 0) * margin:
                        self.apis[api]['threshold'] += tmp
                        leftover -= tmp
                    else:
                        apply = rps.get(api, 0)*margin - self.apis[api]['threshold']
                        self.apis[api]['threshold'] = rps.get(api, 0) * margin
                        leftover -= apply
                        remove.append(api)
                for api in remove:
                    target.remove(api)
            
            while leftover > 0 and i <= len(priority)-1:
                targetAPI = priority[i][0]
                if self.apis[targetAPI]['threshold'] + leftover <= rps.get(targetAPI, 0) * margin:
                    self.apis[targetAPI]['threshold'] += leftover
                    leftover = 0
                    result.append(self.apis[targetAPI])
                    break
                else:
                    apply = rps.get(targetAPI, 0)*margin - self.apis[targetAPI]['threshold']
                    self.apis[targetAPI]['threshold'] = rps.get(targetAPI, 0)*margin
                    leftover -= apply
                    result.append(self.apis[targetAPI])
                    i += 1
            if leftover > 0:
                print(f"Wrong action, leftover: {leftover}")


            apply_threshold_proxy(result)
       
        print(overloaded_services_tmp)

    
    def current_rps(self):
        proxies = {
            'http': global_config["proxy_url"]
        }
        url = global_config["proxy_url"] + "/stats"

        result = {}
        response = requests.get(url, proxies=proxies)
        if not response.ok:
            return None
        body = response.text
        body = body.split("/")[:-1]
        for elem in body:
            elem = elem.split("=")
            result[elem[0]] = float(elem[1])
        
        return result

    """
    Set threshold of APIs to initial threshold
    """
    def reset(self, target=None):
        if target == None:
            apply_threshold_proxy(list(self.apis.values()))
        else:
            target_apis = []
            for api in target:
                target_apis.append(self.apis[api])
            apply_threshold_proxy(target_apis)


def main():
    proxies = {
        'http': 'http://egg3.kaist.ac.kr:8090'
    }
    url = "http://egg3.kaist.ac.kr:8090/thresholds"
    response = requests.get(url, proxies=proxies)
    d = Detector()
    print(d.current_rps())
    quit()
    while True:
        time.sleep(1)
        print(d.detect())

if __name__ == "__main__":
    main()




