/*===============================================================================
Copyright (c) 2016 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2014 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

// Subclassed from AR_EAGLView
#import "EAGLView.h"
#import "Dominoes.h"
#import "Texture.h"
#import <Vuforia/Renderer.h>
#import <Vuforia/VirtualButton.h>
#import <Vuforia/UpdateCallback.h>

#import "Vuforiautils.h"
#import "ShaderUtils.h"


namespace {
    
    // Texture filenames
    const char* textureFilenames[] = {
        "texture_domino.png",
        "green_glow.png",
        "blue_glow.png"
    };
    
    class VirtualButton_UpdateCallback : public Vuforia::UpdateCallback {
        virtual void Vuforia_onUpdate(Vuforia::State& state);
    } vuforiaUpdate;
    
}




@implementation EAGLView

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    
	if (self)
    {
        // create list of textures we want loading - ARViewController will do this for us
        int nTextures = sizeof(textureFilenames) / sizeof(textureFilenames[0]);
        for (int i = 0; i < nTextures; ++i)
            [textureList addObject: [NSString stringWithUTF8String:textureFilenames[i]]];
    }
    return self;
}


// Pass touch events through to the Dominoes module
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch* touch = [touches anyObject];
    CGPoint location = [touch locationInView:self];
    dominoesTouchEvent(ACTION_DOWN, 0, location.x, location.y);
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch* touch = [touches anyObject];
    CGPoint location = [touch locationInView:self];
    dominoesTouchEvent(ACTION_CANCEL, 0, location.x, location.y);
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch* touch = [touches anyObject];
    CGPoint location = [touch locationInView:self];
    dominoesTouchEvent(ACTION_UP, 0, location.x, location.y);
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    UITouch* touch = [touches anyObject];
    CGPoint location = [touch locationInView:self];
    dominoesTouchEvent(ACTION_MOVE, 0, location.x, location.y);
}

////////////////////////////////////////////////////////////////////////////////
// Initialise the application
- (void)initApplication
{
    initializeDominoes();
}


- (void) setup3dObjects
{
    dominoesSetTextures(textures);
}

- (void)initShaders
{
    [super initShaders];
    
    dominoesSetShaderProgramID(shaderProgramID);
    dominoesSetVertexHandle(vertexHandle);
    dominoesSetNormalHandle(normalHandle);
    dominoesSetTextureCoordHandle(textureCoordHandle);
    dominoesSetMvpMatrixHandle(mvpMatrixHandle);
    dominoesSetTexSampler2DHandle(texSampler2DHandle);
}

////////////////////////////////////////////////////////////////////////////////
// Do the things that need doing after initialisation
// called after Vuforia is initialised but before the camera starts
- (void)postInitVuforia
{
    // Here we could make a Vuforia::setHint call to set the maximum
    // number of simultaneous targets                
    // Vuforia::setHint(Vuforia::HINT_MAX_SIMULTANEOUS_IMAGE_TARGETS, 2);
    
    // register for our call back after tracker processing is done
    Vuforia::registerCallback(&vuforiaUpdate);
}


////////////////////////////////////////////////////////////////////////////////
// Draw the current frame using OpenGL
//
// This method is called by Vuforia when it wishes to render the current frame to
// the screen.
//
// *** Vuforia will call this method on a single background thread ***
- (void)renderFrameVuforia
{
    if (APPSTATUS_CAMERA_RUNNING == vUtils.appStatus) {
        [self setFramebuffer];
        renderDominoes();
        [self presentFramebuffer];
    }
}


////////////////////////////////////////////////////////////////////////////////
// Callback function called by the tracker when each tracking cycle has finished
void VirtualButton_UpdateCallback::Vuforia_onUpdate(Vuforia::State& state)
{
    // Process the virtual button
    virtualButtonOnUpdate(state);
}

@end
