try:
    import gymnasium as gym
    IS_GYMNASIUM = True
except ModuleNotFoundError:
    import gym
    IS_GYMNASIUM = False
import ray
from ray.rllib.algorithms import ppo

import random
import numpy as np
from skeleton_simulator import *
# from multi_api_simulator import *
from metric_collector import *
from overload_detection import *
import time
import json
import os



global_config_path = os.path.expanduser("~/TopFullExt/TopFull_master/online_boutique_scripts/src/global_config.json")
with open(global_config_path, "r") as f:
    global_config = json.load(f)
global_config = {
    k: os.path.expandvars(os.path.expanduser(v)) if isinstance(v, str) else v
    for k, v in global_config.items()
}

N_DISCRETE_ACTIONS = 5
feature = 2
MAX_STEPS = 50
addstep = 5
mulstep = 0.1

#collector = Collector(code="online_boutique")
target_api = global_config.get("training_target_api") or global_config["record_target"][0]
MIN_THRESHOLD = 10.0

class MyEnv(gym.Env):
    def __init__(self, env_config):
        self.action_space = gym.spaces.Box(low=np.array([-0.5]), high=np.array([0.5]), dtype=np.float32)
        self.observation_space = gym.spaces.Box(low=np.array([-2000.0, -1000.0]), high=np.array([2000.0, 50000.0]), dtype=np.float32)
        self.MAX_STEPS = MAX_STEPS

    def reset(self, *, seed=None, options=None):
        try:
            super().reset(seed=seed)
        except TypeError:
            # Older gym versions may not accept keyword reset args.
            super().reset()
        self.detector = Detector()
        self.collector = Collector(code=global_config["microservice_code"])
        self.ts = Simulator(addstep, mulstep)
        self.detector.apis[target_api]['threshold'] = 1000
        self.detector.reset([target_api])
        time.sleep(5)

        self.count = 0
        metric = self.collector.query()
        if target_api not in metric:
            print(f"metric for '{target_api}' not ready in reset; use fallback zeros.")
        rps, fail, init_latency95, _ = metric.get(target_api, (0.0, 0.0, 0.0, 0.0))

        self.detector.apis[target_api]['threshold'] = rps if rps > MIN_THRESHOLD else 100.0
        self.threshold = self.detector.apis[target_api]['threshold']
        self.detector.reset([target_api])
        self.goodput = rps - fail

        denom = max(self.threshold, 1e-6)
        self.state = np.array([self.goodput/denom, init_latency95])
        self.reward = 0
        self.done = False
        self.info = {}
        if IS_GYMNASIUM:
            return self.state, self.info
        return self.state

    def step(self, action):
        if self.done:
            print("EPISODE DONE!!!")
            if IS_GYMNASIUM:
                return self.state, self.reward, True, False, self.info
            return self.state, self.reward, True, self.info
        elif self.count == self.MAX_STEPS:

            self.done = True
        else:
            self.count += 1
            metric = self.collector.query()
            rps, fail, latency95, _ = metric.get(target_api, (0.0, 0.0, 0.0, 0.0))
            tmpGoodput = rps - fail

            new_threshold = (1 + float(action)) * self.threshold
            if new_threshold <= MIN_THRESHOLD:
                new_threshold = MIN_THRESHOLD
            dynamic_cap = max(rps * 1.1, MIN_THRESHOLD)
            if new_threshold > dynamic_cap:
                new_threshold = dynamic_cap

            self.detector.apis[target_api]['threshold'] = new_threshold
            apply_threshold_proxy([self.detector.apis[target_api]])

            time.sleep(1)

            metric = self.collector.query()
            rps, fail, latency95, _ = metric.get(target_api, (0.0, 0.0, 0.0, 0.0))
            self.goodput = rps - fail

            deltaGoodput = self.goodput - tmpGoodput
            self.threshold = self.detector.apis[target_api]['threshold']
            
            goodputPerThres = self.goodput / max(self.threshold, 1e-6)

            self.state = np.array([goodputPerThres, latency95])
            self.reward = deltaGoodput
            if latency95 > 1000:
                self.reward -= latency95*0.01
 

        if IS_GYMNASIUM:
            return self.state, self.reward, self.done, False, self.info
        return self.state, self.reward, self.done, self.info



ray.init()
algo = ppo.PPO(env=MyEnv, config={
    "env_config": {},  # config to pass to env class
    'num_workers': 0,
})
checkpoint_path = global_config["checkpoint_path"]
checkpoint_state_file = os.path.join(checkpoint_path, "algorithm_state.pkl")
if os.path.isfile(checkpoint_state_file):
    print(f"Restoring from checkpoint: {checkpoint_path}")
    algo.restore(checkpoint_path)
else:
    print(f"Checkpoint not found ({checkpoint_path}), train from scratch.")


_ = 0
save_path = os.path.abspath("./models_transfer/v1tmp1/rllib_checkpoint")
os.makedirs(save_path, exist_ok=True)
while True:
    if _ % 1 == 0:
        algo.save(save_path)
        print(_)
    _ += 1
    print(algo.train()['episode_reward_mean'])
