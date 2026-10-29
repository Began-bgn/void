"""Converts facenet-pytorch's InceptionResnetV1 (VGGFace2 weights) to Core ML.

Usage (in a venv with `pip install facenet-pytorch coremltools`):
    python scripts/convert-facenet.py NotchDeck/Resources/FaceNet.mlpackage

Model: Inception-ResNet v1, input 160x160 RGB, output 512-d L2-normalised embedding.
Licences: facenet-pytorch code MIT (Tim Esler); weights trained on VGGFace2, whose licence
allows research / non-commercial use only. NotchDeck Face Unlock is personal use.
"""
import sys

import coremltools as ct
import torch
from facenet_pytorch import InceptionResnetV1

out = sys.argv[1]
model = InceptionResnetV1(pretrained="vggface2").eval()
example = torch.rand(1, 3, 160, 160)
traced = torch.jit.trace(model, example)

mlmodel = ct.convert(
    traced,
    # facenet-pytorch's fixed_image_standardization: (x - 127.5) / 128 on 0...255 pixels.
    inputs=[ct.ImageType(name="face", shape=example.shape, scale=1 / 128.0, bias=[-127.5 / 128.0] * 3,
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS14,
)
mlmodel.short_description = "FaceNet (Inception-ResNet v1, VGGFace2) face embedding, 512-d, L2-normalised"
mlmodel.license = "facenet-pytorch: MIT. VGGFace2 weights: research / non-commercial use only."
mlmodel.save(out)

# Self-check: Core ML output matches PyTorch on the same input.
import numpy as np
from PIL import Image
img = (np.random.rand(160, 160, 3) * 255).astype(np.uint8)
ref = model((torch.from_numpy(img).permute(2, 0, 1).float().unsqueeze(0) - 127.5) / 128).detach().numpy()[0]
got = np.array(ct.models.MLModel(out).predict({"face": Image.fromarray(img)})["embedding"]).reshape(-1)
cos = float(np.dot(ref, got) / np.linalg.norm(ref) / np.linalg.norm(got))
print(f"saved {out}; cosine(pytorch, coreml) = {cos:.5f}")
assert cos > 0.999, "conversion mismatch"
