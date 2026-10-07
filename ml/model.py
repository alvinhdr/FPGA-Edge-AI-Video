# =============================================================================
# File   : model.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: The float CNN (the one we train). Same structure as docs/QUANTIZATION.md:
#   28x28x1 -> conv3x3(8)+ReLU -> pool2 -> conv3x3(16)+ReLU -> pool2 -> FC 400->10
# Input is x/255 in [0, 1] (white digit on black), no mean/std normalization.
# =============================================================================
import torch
import torch.nn as nn
import torch.nn.functional as F


class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 8, 3)     # 28x28 -> 26x26
        self.conv2 = nn.Conv2d(8, 16, 3)    # 13x13 -> 11x11
        self.fc = nn.Linear(16 * 5 * 5, 10)  # 5x5 after pool (11 // 2 = 5)

    def forward(self, x, return_acts=False):
        a1 = F.relu(self.conv1(x))                  # [N, 8, 26, 26]
        p1 = F.max_pool2d(a1, 2)                    # [N, 8, 13, 13]
        a2 = F.relu(self.conv2(p1))                 # [N, 16, 11, 11]
        p2 = F.max_pool2d(a2, 2)                    # [N, 16, 5, 5]  (floor: last row/col dropped)
        logits = self.fc(p2.flatten(1))             # flatten order c*25 + y*5 + x
        if return_acts:
            return logits, a1, a2
        return logits


def params_to_numpy(net):
    """Float parameters as float64 numpy arrays, in the layouts of docs/QUANTIZATION.md."""
    sd = {k: v.detach().cpu().double().numpy() for k, v in net.state_dict().items()}
    return {"w1": sd["conv1.weight"], "b1": sd["conv1.bias"],
            "w2": sd["conv2.weight"], "b2": sd["conv2.bias"],
            "wf": sd["fc.weight"], "bf": sd["fc.bias"]}


def net_from_numpy(p):
    net = Net()
    net.load_state_dict({
        "conv1.weight": torch.tensor(p["w1"], dtype=torch.float32), "conv1.bias": torch.tensor(p["b1"], dtype=torch.float32),
        "conv2.weight": torch.tensor(p["w2"], dtype=torch.float32), "conv2.bias": torch.tensor(p["b2"], dtype=torch.float32),
        "fc.weight": torch.tensor(p["wf"], dtype=torch.float32), "fc.bias": torch.tensor(p["bf"], dtype=torch.float32)})
    return net.eval()
