# Hunyuan 3D is licensed under the TENCENT HUNYUAN NON-COMMERCIAL LICENSE AGREEMENT
# except for the third-party components listed below.
# Hunyuan 3D does not impose any additional limitations beyond what is outlined
# in the repsective licenses of these third-party components.
# Users must comply with all terms and conditions of original licenses of these third-party
# components and must ensure that the usage of the third party components adheres to
# all relevant laws and regulations.

# For avoidance of doubts, Hunyuan 3D means the large language models and
# their software and algorithms, including trained model weights, parameters (including
# optimizer states), machine-learning model code, inference-enabling code, training-enabling code,
# fine-tuning enabling code and other elements of the foregoing made publicly available
# by Tencent in accordance with TENCENT HUNYUAN COMMUNITY LICENSE AGREEMENT.

"""
A model worker executes the model.
"""
import argparse
import asyncio
import base64
import logging
import logging.handlers
import os
import sys
import tempfile
import threading
import traceback
import uuid
from io import BytesIO

import torch
import trimesh
import uvicorn
from PIL import Image
from fastapi import FastAPI, Request, File, UploadFile, Form
from fastapi.responses import JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles

from hy3dgen.rembg import BackgroundRemover
from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline, FloaterRemover, DegenerateFaceRemover, FaceReducer, \
    MeshSimplifier
from hy3dgen.texgen import Hunyuan3DPaintPipeline
from hy3dgen.text2image import HunyuanDiTPipeline

LOGDIR = '.'

server_error_msg = "**NETWORK ERROR DUE TO HIGH TRAFFIC. PLEASE REGENERATE OR REFRESH THIS PAGE.**"
moderation_msg = "YOUR INPUT VIOLATES OUR CONTENT MODERATION GUIDELINES. PLEASE TRY AGAIN."

handler = None


def build_logger(logger_name, logger_filename):
    global handler

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Set the format of root handlers
    if not logging.getLogger().handlers:
        logging.basicConfig(level=logging.INFO)
    logging.getLogger().handlers[0].setFormatter(formatter)

    # Redirect stdout and stderr to loggers
    stdout_logger = logging.getLogger("stdout")
    stdout_logger.setLevel(logging.INFO)
    sl = StreamToLogger(stdout_logger, logging.INFO)
    sys.stdout = sl

    stderr_logger = logging.getLogger("stderr")
    stderr_logger.setLevel(logging.ERROR)
    sl = StreamToLogger(stderr_logger, logging.ERROR)
    sys.stderr = sl

    # Get logger
    logger = logging.getLogger(logger_name)
    logger.setLevel(logging.INFO)

    # Add a file handler for all loggers
    if handler is None:
        os.makedirs(LOGDIR, exist_ok=True)
        filename = os.path.join(LOGDIR, logger_filename)
        handler = logging.handlers.TimedRotatingFileHandler(
            filename, when='D', utc=True, encoding='UTF-8')
        handler.setFormatter(formatter)

        for name, item in logging.root.manager.loggerDict.items():
            if isinstance(item, logging.Logger):
                item.addHandler(handler)

    return logger


class StreamToLogger(object):
    """
    Fake file-like stream object that redirects writes to a logger instance.
    """

    def __init__(self, logger, log_level=logging.INFO):
        self.terminal = sys.stdout
        self.logger = logger
        self.log_level = log_level
        self.linebuf = ''

    def __getattr__(self, attr):
        return getattr(self.terminal, attr)

    def write(self, buf):
        temp_linebuf = self.linebuf + buf
        self.linebuf = ''
        for line in temp_linebuf.splitlines(True):
            # From the io.TextIOWrapper docs:
            #   On output, if newline is None, any '\n' characters written
            #   are translated to the system default line separator.
            # By default sys.stdout.write() expects '\n' newlines and then
            # translates them so this is still cross platform.
            if line[-1] == '\n':
                self.logger.log(self.log_level, line.rstrip())
            else:
                self.linebuf += line

    def flush(self):
        if self.linebuf != '':
            self.logger.log(self.log_level, self.linebuf.rstrip())
        self.linebuf = ''


def pretty_print_semaphore(semaphore):
    if semaphore is None:
        return "None"
    return f"Semaphore(value={semaphore._value}, locked={semaphore.locked()})"


SAVE_DIR = 'gradio_cache'
os.makedirs(SAVE_DIR, exist_ok=True)

worker_id = str(uuid.uuid4())[:6]
logger = build_logger("controller", f"{SAVE_DIR}/controller.log")


def load_image_from_base64(image):
    return Image.open(BytesIO(base64.b64decode(image)))


class ModelWorker:
    def __init__(self,
                 model_path=os.getenv('MODEL_PATH', 'tencent/Hunyuan3D-2mini'),
                 tex_model_path=os.getenv('TEX_MODEL_PATH', 'tencent/Hunyuan3D-2'),
                 mv_model_path=os.getenv('MV_MODEL_PATH', 'tencent/Hunyuan3D-2mv'),
                 subfolder='hunyuan3d-dit-v2-mini-turbo',
                 mv_subfolder='hunyuan3d-dit-v2-mv',
                 device='cuda',
                 enable_tex=False,
                 enable_multiview=False):
        self.model_path = model_path
        self.mv_model_path = mv_model_path
        self.worker_id = worker_id
        self.device = device
        self.enable_multiview = enable_multiview
        logger.info(f"Loading the model {model_path} on worker {worker_id} ...")

        self.rembg = BackgroundRemover()
        
        # Load single view pipeline
        self.pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
            model_path,
            subfolder=subfolder,
            use_safetensors=True,
            device=device,
        )
        self.pipeline.enable_flashvdm(mc_algo='mc')
        
        # Load multiview pipeline if enabled
        if enable_multiview:
            logger.info(f"Loading multiview model {mv_model_path} ...")
            self.pipeline_mv = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
                mv_model_path,
                subfolder=mv_subfolder,
                variant='fp16',
                device=device,
            )
        else:
            self.pipeline_mv = None
            
        # self.pipeline_t2i = HunyuanDiTPipeline(
        #     'Tencent-Hunyuan/HunyuanDiT-v1.1-Diffusers-Distilled',
        #     device=device
        # )
        if enable_tex:
            self.pipeline_tex = Hunyuan3DPaintPipeline.from_pretrained(tex_model_path)

    def get_queue_length(self):
        if model_semaphore is None:
            return 0
        else:
            return args.limit_model_concurrency - model_semaphore._value + (len(
                model_semaphore._waiters) if model_semaphore._waiters is not None else 0)

    def get_status(self):
        return {
            "speed": 1,
            "queue_length": self.get_queue_length(),
        }

    @torch.inference_mode()
    def generate(self, uid, params):
        # Check if this is a multiview generation
        is_multiview = params.get('multiview', False)
        
        if is_multiview:
            # Handle multiview images
            if 'images' in params:
                # Expect params['images'] to be a dict with front, left, back base64 images
                images = {}
                for view in ['front', 'left', 'back']:
                    if view in params['images']:
                        images[view] = load_image_from_base64(params['images'][view])
                        images[view] = self.rembg(images[view])
                    else:
                        raise ValueError(f"Missing {view} image for multiview generation")
                params['image'] = images
            else:
                raise ValueError("No images provided for multiview generation")
                
            # Use multiview pipeline
            if self.pipeline_mv is None:
                raise ValueError("Multiview pipeline not loaded. Enable multiview mode.")
            pipeline_to_use = self.pipeline_mv
            
        else:
            # Handle single image
            if 'image' in params:
                image = params["image"]
                image = load_image_from_base64(image)
                image = self.rembg(image)
                params['image'] = image
            else:
                if 'text' in params:
                    text = params["text"]
                    image = self.pipeline_t2i(text)
                    image = self.rembg(image)
                    params['image'] = image
                else:
                    raise ValueError("No input image or text provided")
            
            # Use single view pipeline
            pipeline_to_use = self.pipeline

        if 'mesh' in params:
            mesh = trimesh.load(BytesIO(base64.b64decode(params["mesh"])), file_type='glb')
        else:
            seed = params.get("seed", 1234)
            params['generator'] = torch.Generator(self.device).manual_seed(seed)
            
            # Set appropriate default parameters based on pipeline type
            if is_multiview:
                params['octree_resolution'] = params.get("octree_resolution", 380)
                params['num_inference_steps'] = params.get("num_inference_steps", 50)
                params['num_chunks'] = params.get("num_chunks", 20000)
            else:
                params['octree_resolution'] = params.get("octree_resolution", 128)
                params['num_inference_steps'] = params.get("num_inference_steps", 5)
                params['mc_algo'] = 'mc'
                
            params['guidance_scale'] = params.get('guidance_scale', 5.0)
            
            import time
            start_time = time.time()
            mesh = pipeline_to_use(**params)[0]
            logger.info("--- %s seconds ---" % (time.time() - start_time))

        if params.get('texture', False):
            mesh = FloaterRemover()(mesh)
            mesh = DegenerateFaceRemover()(mesh)
            mesh = FaceReducer()(mesh, max_facenum=params.get('face_count', 40000))
            
            # For texture generation, use the front image if multiview
            texture_image = params['image']['front'] if is_multiview else params['image']
            mesh = self.pipeline_tex(mesh, texture_image)

        type = params.get('type', 'glb')
        with tempfile.NamedTemporaryFile(suffix=f'.{type}', delete=False) as temp_file:
            mesh.export(temp_file.name)
            mesh = trimesh.load(temp_file.name)
            save_path = os.path.join(SAVE_DIR, f'{str(uid)}.{type}')
            mesh.export(save_path)

        torch.cuda.empty_cache()
        return save_path, uid


app = FastAPI()
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 你可以指定允许的来源
    allow_credentials=True,
    allow_methods=["*"],  # 允许所有方法
    allow_headers=["*"],  # 允许所有头部
)

# Mount static files for frontend
app.mount("/static", StaticFiles(directory="static"), name="static")

# Serve the frontend HTML
@app.get("/")
async def serve_frontend():
    return FileResponse('static/index.html')


@app.post("/generate")
async def generate(request: Request):
    logger.info("Worker generating...")
    params = await request.json()
    uid = uuid.uuid4()
    try:
        file_path, uid = worker.generate(uid, params)
        return FileResponse(file_path)
    except ValueError as e:
        traceback.print_exc()
        print("Caught ValueError:", e)
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)
    except torch.cuda.CudaError as e:
        print("Caught torch.cuda.CudaError:", e)
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)
    except Exception as e:
        print("Caught Unknown Error", e)
        traceback.print_exc()
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)


@app.post("/generate-form")
async def generate_form(
    image: UploadFile = File(...),
    seed: int = Form(1234),
    octree_resolution: int = Form(128),
    num_inference_steps: int = Form(5),
    guidance_scale: float = Form(5.0),
    texture: bool = Form(False),
    face_count: int = Form(40000)
):
    """
    Form-based endpoint for frontend file uploads
    """
    logger.info("Worker generating from form data...")
    
    try:
        # Read the uploaded image file
        image_data = await image.read()
        
        # Convert to base64 for the existing generate function
        image_base64 = base64.b64encode(image_data).decode('utf-8')
        
        # Build params in the expected format
        params = {
            "image": image_base64,
            "seed": seed,
            "octree_resolution": octree_resolution,
            "num_inference_steps": num_inference_steps,
            "guidance_scale": guidance_scale,
            "texture": texture,
            "face_count": face_count
        }
        
        uid = uuid.uuid4()
        file_path, uid = worker.generate(uid, params)
        return FileResponse(file_path)
        
    except ValueError as e:
        traceback.print_exc()
        print("Caught ValueError:", e)
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)
    except torch.cuda.CudaError as e:
        print("Caught torch.cuda.CudaError:", e)
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)
    except Exception as e:
        print("Caught Unknown Error", e)
        traceback.print_exc()
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)


@app.post("/generate-multiview-form")
async def generate_multiview_form(
    front_image: UploadFile = File(...),
    left_image: UploadFile = File(...),
    back_image: UploadFile = File(...),
    seed: int = Form(12345),
    octree_resolution: int = Form(380),
    num_inference_steps: int = Form(50),
    num_chunks: int = Form(20000),
    guidance_scale: float = Form(5.0),
    texture: bool = Form(False),
    face_count: int = Form(40000)
):
    """
    Form-based endpoint for multiview frontend file uploads
    """
    logger.info("Worker generating from multiview form data...")
    
    try:
        # Read and encode all three images
        front_data = await front_image.read()
        left_data = await left_image.read()
        back_data = await back_image.read()
        
        # Convert to base64 for the existing generate function
        images_base64 = {
            "front": base64.b64encode(front_data).decode('utf-8'),
            "left": base64.b64encode(left_data).decode('utf-8'),
            "back": base64.b64encode(back_data).decode('utf-8')
        }
        
        # Build params in the expected format
        params = {
            "images": images_base64,
            "multiview": True,
            "seed": seed,
            "octree_resolution": octree_resolution,
            "num_inference_steps": num_inference_steps,
            "num_chunks": num_chunks,
            "guidance_scale": guidance_scale,
            "texture": texture,
            "face_count": face_count
        }
        
        uid = uuid.uuid4()
        file_path, uid = worker.generate(uid, params)
        return FileResponse(file_path)
        
    except ValueError as e:
        traceback.print_exc()
        print("Caught ValueError:", e)
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)
    except torch.cuda.CudaError as e:
        print("Caught torch.cuda.CudaError:", e)
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)
    except Exception as e:
        print("Caught Unknown Error", e)
        traceback.print_exc()
        ret = {
            "text": server_error_msg,
            "error_code": 1,
        }
        return JSONResponse(ret, status_code=404)


@app.post("/send")
async def generate(request: Request):
    logger.info("Worker send...")
    params = await request.json()
    uid = uuid.uuid4()
    threading.Thread(target=worker.generate, args=(uid, params,)).start()
    ret = {"uid": str(uid)}
    return JSONResponse(ret, status_code=200)


@app.get("/status/{uid}")
async def status(uid: str):
    save_file_path = os.path.join(SAVE_DIR, f'{uid}.glb')
    print(save_file_path, os.path.exists(save_file_path))
    if not os.path.exists(save_file_path):
        response = {'status': 'processing'}
        return JSONResponse(response, status_code=200)
    else:
        base64_str = base64.b64encode(open(save_file_path, 'rb').read()).decode()
        response = {'status': 'completed', 'model_base64': base64_str}
        return JSONResponse(response, status_code=200)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=str, default="0.0.0.0")
    parser.add_argument("--port", type=int, default=os.getenv('HOST_PORT', 8081))
    parser.add_argument("--model_path", type=str, default='tencent/Hunyuan3D-2mini')
    parser.add_argument("--tex_model_path", type=str, default='tencent/Hunyuan3D-2')
    parser.add_argument("--mv_model_path", type=str, default='tencent/Hunyuan3D-2mv')
    parser.add_argument("--device", type=str, default="cuda")
    parser.add_argument("--limit-model-concurrency", type=int, default=5)
    parser.add_argument('--enable_tex', action='store_true')
    parser.add_argument('--enable_multiview', action='store_true')
    args = parser.parse_args()
    logger.info(f"args: {args}")

    model_semaphore = asyncio.Semaphore(args.limit_model_concurrency)

    # worker = ModelWorker(model_path=args.model_path, device=args.device, enable_tex=args.enable_tex,
    #                      tex_model_path=args.tex_model_path, mv_model_path=args.mv_model_path,
    #                      enable_multiview=args.enable_multiview)
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
