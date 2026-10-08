"""Converts Google's AIY food classifier (2,023 dishes, Apache-2.0) to Core ML for the iOS app.

usage: convert_food_model.py <tf1 hub module dir> <tflite dir> <out dir> [test photo]
"""
import os, sys, glob
import numpy as np
import tensorflow as tf
import tensorflow_hub as hub
import coremltools as ct

tf1_dir, lite_dir, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)

# Labels come from the TFLite metadata (a zip appended to the .tflite file).
lite = glob.glob(os.path.join(lite_dir, "**/*.tflite"), recursive=True)[0]
import zipfile
with zipfile.ZipFile(lite) as z:
    for n in z.namelist():
        print("metadata file", n, z.read(n)[:300])
    files = {n: z.read(n).decode(errors="replace").splitlines() for n in z.namelist()}
# Prefer the file with readable dish names over Knowledge Graph ids (/g/...)
name = max(files, key=lambda n: sum(1 for l in files[n] if l and not l.startswith("/")))
labels = files[name]
if "," in labels[1] and labels[0].lower().startswith("id"):
    labels = [l.split(",", 1)[1] for l in labels[1:]]
print("labels from", name, len(labels), labels[:8])

module = hub.load(tf1_dir)
print("signatures", list(module.signatures.keys()))
sig = module.signatures["default"] if "default" in module.signatures else module.signatures[list(module.signatures)[0]]
print("inputs", sig.structured_input_signature, "outputs", sig.structured_outputs)
in_name = list(sig.structured_input_signature[1].keys())[0]
out_name = list(sig.structured_outputs.keys())[0]

@tf.function(input_signature=[tf.TensorSpec([1, 192, 192, 3], tf.float32, name="image")])
def classify(image):
    return sig(**{in_name: image})[out_name]

x = np.random.rand(1, 192, 192, 3).astype(np.float32)
print("output shape", classify(x).shape)
# The hub module takes pixels in [0, 1].
mlmodel = ct.convert([classify.get_concrete_function()], source="tensorflow",
                     inputs=[ct.ImageType(name="image", shape=(1, 192, 192, 3), scale=1 / 255.0)],
                     classifier_config=ct.ClassifierConfig(labels[: classify(x).shape[-1]]),
                     minimum_deployment_target=ct.target.iOS17)
mlmodel.short_description = "Google AIY food classifier V1 (Apache-2.0), 2,023 dishes"
mlmodel.save(os.path.join(out, "FoodClassifier.mlpackage"))
open(os.path.join(out, "labels.txt"), "w").write("\n".join(labels))
print("saved")

# Smoke test on a real photo, if one was given: prints the top dishes
if len(sys.argv) > 4 and os.path.exists(sys.argv[4]):
    from PIL import Image
    img = Image.open(sys.argv[4]).convert("RGB").resize((192, 192))
    try:
        pred = mlmodel.predict({"image": img})
        probs = [v for k, v in pred.items() if isinstance(v, dict)][0]
        print("top", sorted(probs.items(), key=lambda kv: -kv[1])[:5])
    except Exception as e:
        print("prediction skipped:", e)
    arr = np.asarray(img, dtype=np.float32)[None] / 255.0
    tf_probs = classify(arr).numpy()[0]
    print("tensorflow top", [(labels[i], float(tf_probs[i])) for i in tf_probs.argsort()[::-1][:5]])
