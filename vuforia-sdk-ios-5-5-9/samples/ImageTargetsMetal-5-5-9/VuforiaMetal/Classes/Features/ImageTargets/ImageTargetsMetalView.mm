/*===============================================================================
 Copyright (c) 2015-2016 PTC Inc. All Rights Reserved. Confidential and Proprietary -
 Protected under copyright and other laws.
 Vuforia is a trademark of PTC Inc., registered in the United States and other
 countries.
 ===============================================================================*/

#import "ImageTargetsMetalView.h"
#import <QuartzCore/CAMetalLayer.h>
#import <Vuforia/Vuforia.h>
#import <Vuforia/Vuforia_iOS.h>
#import <Vuforia/Renderer.h>
#import <Vuforia/MetalRenderer.h>
#import <Vuforia/State.h>
#import <Vuforia/Tool.h>
#import <Vuforia/TrackableResult.h>
#import <Vuforia/CameraDevice.h>

#import "Teapot.h"
#import "Texture.h"
#import "SampleApplicationUtils.h"

namespace {
    // Model scale factor
    const float kObjectScaleNormal = 3.0f;
    
    const uint32_t kMVPMatrixBufferSize = sizeof(Vuforia::Matrix44F);
}

@interface ImageTargetsMetalView ()
@property (nonatomic) CGFloat contentScaleFactor;
@end

@implementation ImageTargetsMetalView
@synthesize vapp = vapp;

// You must implement this method, which ensures the view's underlying layer is
// of type CAMetalLayer
+ (Class)layerClass
{
    return [CAMetalLayer class];
}

- (id)initWithFrame:(CGRect)frame appSession:(SampleApplicationSession *) app
{
    self = [super initWithFrame:frame];
    
    if (self) {
        vapp = app;
        [self determineContentScaleFactor];
        [self setContentScaleFactor:self.contentScaleFactor];
        
        // --- Metal device ---
        // Get the system default metal device
        metalDevice = MTLCreateSystemDefaultDevice();
        
        // Metal command queue
        metalCommandQueue = [metalDevice newCommandQueue];
        
        // Create a dispatch semaphore, used to synchronise command execution
        commandExecuting = dispatch_semaphore_create(1);
        
        // --- Metal layer ---
        // Create a CAMetalLayer and set its frame to match that of the view
        CAMetalLayer* layer = (CAMetalLayer*)[self layer];
        layer.device = metalDevice;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = true;
        layer.contentsScale = self.contentScaleFactor;
        
        // --- Metal vertex, index and MVP buffers ---
        // Teapot vertex buffer
        vertexBufferTeapot = [metalDevice newBufferWithBytes:teapotVertices length:sizeof(teapotVertices) options:MTLResourceOptionCPUCacheModeDefault];
        
        // Teapot index buffer
        indexBufferTeapot = [metalDevice newBufferWithBytes:teapotIndices length:sizeof(teapotIndices) options:MTLResourceOptionCPUCacheModeDefault];
        
        // Teapot texture coordinate buffer
        NSUInteger teapotTexCoordsSize = sizeof(teapotTexCoords);
        texCoordBufferTeapot = [metalDevice newBufferWithBytes:teapotTexCoords
                                                        length:teapotTexCoordsSize
                                                       options:MTLResourceOptionCPUCacheModeDefault];
        
        // Model view projection matrix buffer
        mvpBuffer = [metalDevice newBufferWithLength:kMVPMatrixBufferSize options:0];
        
		
        // --- Metal pipeline ---
        // Get the default library from the bundle (Metal shaders)
        id<MTLLibrary> library = [metalDevice newDefaultLibrary];
        
        id<MTLFunction> augmentationVertexFunc = [library newFunctionWithName:@"texturedVertex"];
        id<MTLFunction> augmentationFragmentFunc = [library newFunctionWithName:@"texturedFragment"];
        
        // Set up pipeline state descriptor.  Note that the video background and
        // augmention pipeline states are the same, so could be represented by
        // one MTLRenderPipelineDescriptor.  We use two for demonstration only
        MTLRenderPipelineDescriptor* stateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        NSError* error = nil;
        
        // === Augmentation ===
        stateDescriptor.vertexFunction = augmentationVertexFunc;
        stateDescriptor.fragmentFunction = augmentationFragmentFunc;
        stateDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat;
        
        error = nil;
        pipelineStateTeapot = [metalDevice newRenderPipelineStateWithDescriptor:stateDescriptor error:&error];
        
        if (nil == pipelineStateTeapot) {
            NSLog(@"Failed to create augmentation render pipeline state: %@", [error localizedDescription]);
        }
        
        // Fragment depth stencil
        MTLDepthStencilDescriptor* depthStencilDescriptor = [[MTLDepthStencilDescriptor alloc] init];
        depthStencilDescriptor.depthCompareFunction = MTLCompareFunctionLess;
        depthStencilDescriptor.depthWriteEnabled = YES;
        depthStencilState = [metalDevice newDepthStencilStateWithDescriptor:depthStencilDescriptor];
        
        // Load the teapot texture data
        Texture* texture = [[Texture alloc] initWithImageFile:@"TextureTeapotBrass.png"];
        
        MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                     width:[texture width]
                                                                                                    height:[texture height]
                                                                                                 mipmapped:YES];
        textureTeapot = [metalDevice newTextureWithDescriptor:textureDescriptor];
        
        MTLRegion region = MTLRegionMake2D(0, 0, [texture width], [texture height]);
        [textureTeapot replaceRegion:region mipmapLevel:0 withBytes:[texture pngData] bytesPerRow:[texture width] * [texture channels]];
    }
    
    return self;
}

- (void)determineContentScaleFactor
{
    UIScreen* mainScreen = [UIScreen mainScreen];
    
    if ([mainScreen respondsToSelector:@selector(nativeScale)]) {
        self.contentScaleFactor = [mainScreen nativeScale];
    }
    else if ([mainScreen respondsToSelector:@selector(displayLinkWithTarget:selector:)] && 2.0 == [UIScreen mainScreen].scale) {
        self.contentScaleFactor = 2.0f;
    }
    else {
        self.contentScaleFactor = 1.0f;
    }
}

//------------------------------------------------------------------------------
#pragma mark - UIGLViewProtocol protocol

// Draw the current frame using Metal
//
// This method is called by Vuforia when it wishes to render the current frame to
// the screen.
//
// *** Vuforia will call this method periodically on a background thread ***
- (void)renderFrameVuforia
{
    // ========== Set up ==========
    CAMetalLayer* layer = (CAMetalLayer*)self.layer;
    
    MTLViewport viewport;
    viewport.originX = 0.0f;
    viewport.originY = 0.0f;
    viewport.height = layer.drawableSize.height;
    viewport.width = layer.drawableSize.width;
    viewport.znear = 0.0f;
    viewport.zfar = 1.0f;
    
    // --- Command buffer ---
    // Get the command buffer from the command queue
    id<MTLCommandBuffer>commandBuffer = [metalCommandQueue commandBuffer];
    
    // Get the next drawable from the CAMetalLayer
    id<CAMetalDrawable> drawable = [layer nextDrawable];

    // It's possible for nextDrawable to return nil, which means a call to
    // renderCommandEncoderWithDescriptor will fail
    if (!drawable) {
        return;
    }

    // Wait for exclusive access to the GPU
    dispatch_semaphore_wait(commandExecuting, DISPATCH_TIME_FOREVER);
    
    // -- Render pass descriptor ---
    // Set up a render pass decriptor
    MTLRenderPassDescriptor* renderPassDescriptor = [[MTLRenderPassDescriptor  alloc] init];

    // Draw to the drawable's texture
    renderPassDescriptor.colorAttachments[0].texture = [drawable texture];
    // Avoid the overhead of clearing the colour attachment
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    // Store the data in the texture when rendering is complete
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    // Get a command encoder to encode into the command buffer
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    // Begin Vuforia rendering for this frame, retrieving the tracking state
    Vuforia::MetalRenderData renderData;
    renderData.mData.drawableTexture = [drawable texture];
    renderData.mData.commandEncoder = encoder;
    Vuforia::State state = Vuforia::Renderer::getInstance().begin(&renderData);

    bool render = Vuforia::Renderer::getInstance().drawVideoBackground();

    if (render) {
        // ========== Vuforia tracking ==========
        [encoder setRenderPipelineState:pipelineStateTeapot];
        
        // Enable depth testing
        [encoder setDepthStencilState:depthStencilState];
        
        for (int i = 0; i < state.getNumTrackableResults(); ++i) {
            // Get the trackable result
            const Vuforia::TrackableResult* result = state.getTrackableResult(i);
            
            Vuforia::Matrix44F modelViewMatrix = Vuforia::Tool::convertPose2GLMatrix(result->getPose());
            Vuforia::Matrix44F modelViewProjection;
            
            SampleApplicationUtils::translatePoseMatrix(0.0f, 0.0f, kObjectScaleNormal, &modelViewMatrix.data[0]);
            SampleApplicationUtils::scalePoseMatrix(kObjectScaleNormal, kObjectScaleNormal, kObjectScaleNormal, &modelViewMatrix.data[0]);
            
            SampleApplicationUtils::multiplyMatrix(&vapp.projectionMatrix.data[0], &modelViewMatrix.data[0], &modelViewProjection.data[0]);
            
            
            // ========== Render the augmentation ==========
            // Set the vertex buffer
            [encoder setVertexBuffer:vertexBufferTeapot offset:0 atIndex:0];
            
            // Set the fragment texture
            [encoder setFragmentTexture:textureTeapot atIndex:0];
            
            // Set the texture coordinate buffer
            [encoder setVertexBuffer:texCoordBufferTeapot
                              offset:0
                             atIndex:2];
            
            // Load MVP constant buffer data into appropriate buffer
            uint8_t* buffer = (uint8_t*)[mvpBuffer contents];
            memcpy(buffer, &modelViewProjection.data[0], sizeof(modelViewProjection));
            [encoder setVertexBuffer:mvpBuffer offset:0 atIndex:1];
            
            // Set the viewport
            [encoder setViewport:viewport];
            
            // Draw the geometry
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:NUM_TEAPOT_OBJECT_INDEX indexType:MTLIndexTypeUInt16 indexBuffer:indexBufferTeapot indexBufferOffset:0];
        }
    }
    
    // Pass Metal context data to Vuforia (we may have changed the encoder since
    // calling Vuforia::Renderer::begin)
    Vuforia::Renderer::getInstance().end(&renderData);
    
    
    // ========== Finish Metal rendering ==========
    [encoder endEncoding];

    // Commit the rendering commands only if there is something to render
    if (render) {
        // Command completed handler
        [commandBuffer addCompletedHandler:^(id <MTLCommandBuffer> cmdb) {
            dispatch_semaphore_signal(commandExecuting);
        }];


        // Present the drawable when the command buffer has been executed (Metal
        // calls to CoreAnimation to tell it to put the texture on the display when
        // the rendering is complete)
        [commandBuffer presentDrawable:drawable];

        // Commit the command buffer for execution as soon as possible
        [commandBuffer commit];
    }
    else {
        // Signal the semaphore to prevent deadlock on the next frame
        dispatch_semaphore_signal(commandExecuting);
    }
}


@end
