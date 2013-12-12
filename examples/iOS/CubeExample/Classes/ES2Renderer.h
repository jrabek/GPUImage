#import "ESRenderer.h"

#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <GLKit/GLKMathUtils.h>
#import <GLKit/GLKVector3.h>
#import <GLKit/GLKMatrix4.h>
#import "GPUImage.h"

@class PVRTexture;

@interface ES2Renderer : NSObject <ESRenderer, GPUImageTextureOutputDelegate>
{
@private
    EAGLContext *context;

	GLuint textureForCubeFace, outputTexture;
    
    // The pixel dimensions of the CAEAGLLayer
    GLint backingWidth;
    GLint backingHeight;

    // The OpenGL ES names for the framebuffer and renderbuffer used to render to this view
    GLuint defaultFramebuffer, colorRenderbuffer;

	CATransform3D currentCalculatedMatrix;
    GLfloat currentModelViewMatrix[16];
    GLKMatrix4 glkModelViewMatrix;
    GLfloat screenWidth;
    GLfloat screenHeight;

    GLuint program;
    
    GPUImageVideoCamera *videoCamera;
    GPUImageFilter *inputFilter;
    GPUImageTextureOutput *textureOutput;

}

@property(readonly) GLuint outputTexture;
@property(nonatomic, copy) void(^newFrameAvailableBlock)(void);

- (id)initWithSize:(CGSize)newSize;

- (void)render;
- (void)convert3DTransform:(CATransform3D *)transform3D toMatrix:(GLfloat *)matrix;
- (void)startCameraCapture;

@end

