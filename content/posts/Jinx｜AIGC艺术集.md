---
title: "Jinx｜AIGC艺术集"
date: 2025-04-18T15:17:30+08:00
# weight: 1
# aliases: ["/first"]
tags: ["AIGC艺术集"]
author: "Me"
# author: ["Me", "You"] # multiple authors
showToc: true
TocOpen: false
draft: false
hidemeta: false
comments: false
# description: "Desc Text."
canonicalURL: "https://canonical.url/to/page"
disableShare: false
disableHLJS: false
hideSummary: false
searchHidden: true
ShowReadingTime: true
ShowBreadCrumbs: true
ShowPostNavLinks: true
ShowWordCount: true
ShowRssButtonInSectionTermList: true
UseHugoToc: true
cover:
    image: https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/jinx01.PNG # image path/url
    alt: "<alt text>" # alt text
    caption: "<text>" # display caption under cover
    # relative: false # when using page bundles set this to true
    hidden: false # only hide on current single page
# editPost:
#     URL: "https://github.com/<path_to_repo>/content"
#     Text: "Suggest Changes" # edit text
#     appendFilePath: true # to append file path to Edit link
---
![002](https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/jinx02.PNG)    

第一次尝试自己训练LoRA模型   

绘制参数如下：   
```txt
model：
GhostMix-V2.0-fp16-BakedVAE    

prompt：
jinx,(masterpiece, best quality:1.3), (flat color:1.3),(colorful:1.3),looking at viewer,1girl,solo,floating colorful water,(2D:1.3), <lora:zyd232_InkStyle_v1_0:0.6> <lora:jinx:1>   

Negative prompt: 
(worst quality, low quality:2), monochrome, zombie,overexposure, watermark,text,bad anatomy,bad hand,extra hands,extra fingers,too many fingers,fused fingers,bad arm,distorted arm,extra arms,fused arms,extra legs,missing leg,disembodied leg,extra nipples, detached arm, liquid hand,inverted hand,disembodied limb, small breasts, loli, oversized head,extra body,completely nude, extra navel,easynegative,(hair between eyes),sketch, duplicate, ugly, huge eyes, text, logo, worst face, (bad and mutated hands:1.3), (blurry:2.0), horror, geometry, bad_prompt, (bad hands), (missing fingers), multiple limbs, bad anatomy, (interlocked fingers:1.2), Ugly Fingers, (extra digit and hands and fingers and legs and arms:1.4), ((2girl)), (deformed fingers:1.2), (long fingers:1.2),(bad-artist-anime), bad-artist, bad hand, extra legs ,(ng_deepnegative_v1_75t)   

other parameters：
Steps: 30, Sampler: DPM++ 2M Karras, CFG scale: 5, Size: 960x540, Model hash: e3edb8a26f, Model: GhostMix-V2.0-fp16-BakedVAE, Denoising strength: 0.5, Clip skip: 2, Hires upscale: 2, Hires steps: 20, Hires upscaler: R-ESRGAN 4x+ Anime6B, Lora hashes: "zyd232_InkStyle_v1_0: 96718d4b1924, jinx: faecb6cfeccd", TI hashes: "EasyNegative: c74b4e810b03, ng_deepnegative_v1_75t: 54e7e4826d53", Version: v1.5.1
```

