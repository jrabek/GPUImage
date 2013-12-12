#import "ES2Renderer.h"

#define GL_CHECK_ERR                                      \
{                                                         \
    GLenum errCode;                                       \
    if ((errCode = glGetError()) != GL_NO_ERROR) {        \
        NSLog(@"(%d) OpenGL Error: %d\n", __LINE__, errCode);          \
                raise(SIGTRAP); \
    }                                                     \
}


// uniform index
enum {
    UNIFORM_MODELVIEWMATRIX,
    UNIFORM_TEXTURE,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];

// attribute index
enum {
    ATTRIB_VERTEX,
    ATTRIB_TEXTUREPOSITION,
    ATTRIB_DEFORM,
    NUM_ATTRIBUTES
};

GLuint imageVerticeBuffer[1];
GLuint imageIndexBuffer[1];

@interface ES2Renderer (PrivateMethods)
- (BOOL)loadShaders;
- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)file;
- (BOOL)linkProgram:(GLuint)prog;
- (BOOL)validateProgram:(GLuint)prog;
@end

@implementation ES2Renderer

@synthesize outputTexture;
@synthesize newFrameAvailableBlock;

const int imageMeshWidth = 20;
const int imageMeshHeight = 20;
const int imageMeshNumVertices = (imageMeshWidth + 1) * (imageMeshHeight + 1);
const int numIndPerRow = imageMeshWidth * 2 + 2;
const int numIndDegensReq = (imageMeshHeight - 1) * 2;
const int imageMeshNumIndices = numIndPerRow * imageMeshHeight + numIndDegensReq;

float *meshPoints;
float *meshCoords;

typedef struct
{
    GLfloat x, y, z; // Vertex
    GLfloat dx, dy; // deform amount
    GLfloat nx, ny, nz; // Normal
    GLfloat s0, t0; // Texcoord
} vertex_t;

vertex_t *imageVertices;
GLushort *imageIndices;

void InitPlane(uint32_t w, uint32_t h, vertex_t *vertices, GLushort *indices)
{
    w++, h++;
    uint32_t x, y, vert_off;
    GLfloat x_step = 1.0/((GLfloat)w);
    GLfloat y_step = 1.0/((GLfloat)h);
    
    vert_off = 0;
    
    for (y = 0; y < h; y++)
    {
        for (x = 0; x < w; x++)
        {
            vertices[vert_off].x = (GLfloat)x * x_step;
            vertices[vert_off].y = (GLfloat)y * y_step;
            vertices[vert_off].z = 0.0;
            vertices[vert_off].dx = 0.0;
            vertices[vert_off].dy = 0.0;
            vertices[vert_off].s0 = (GLfloat)x * x_step;
            vertices[vert_off].t0 = (GLfloat)y * y_step;
            ++vert_off;
        }
    }
 
    h--;
    int i = 0;
    for(int y = 0; y < h; y++)
    {
        int base = y * w;
        
        for(x = 0; x < w; x++)
        {
            indices[i++] = (GLuint)(base + x);
            indices[i++] = (GLuint)(base + w + x);
        }
        // add a degenerate triangle (except in a last row)
        if(y < h - 1)
        {
            indices[i++] = (GLuint)((y + 1) * w + (w - 1));
            indices[i++] = (GLuint)((y + 1) * w);
        }
    }

}


- (id)initWithSize:(CGSize)newSize;
{
    if ((self = [super init]))
    {
        // Need to use a share group based on the GPUImage context to share textures with the 3-D scene
        context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:[[[GPUImageContext sharedImageProcessingContext] context] sharegroup]];

        if (!context || ![EAGLContext setCurrentContext:context] || ![self loadShaders])
        {
            [self release];
            return nil;
        }
        
        backingWidth = (int)newSize.width;
        backingHeight = (int)newSize.height;
		
		//currentCalculatedMatrix = CATransform3DIdentity;
		//currentCalculatedMatrix = CATransform3DScale(currentCalculatedMatrix, 0.5, 0.5 * (320.0/480.0), 0.5);
        //currentCalculatedMatrix = CATransform3DMakeRotation(M_PI / 2.0, 1.0, 0.0, 0.0);
        currentCalculatedMatrix = CATransform3DMakeRotation(M_PI, 1.0, 0.0, 0.0);
        currentCalculatedMatrix = CATransform3DRotate(currentCalculatedMatrix, -M_PI_2, 0.0, 0.0, 1.0);
        currentCalculatedMatrix = CATransform3DScale(currentCalculatedMatrix, 2.0, 2.0, 0.0);
        currentCalculatedMatrix = CATransform3DTranslate(currentCalculatedMatrix, -0.46, -0.48, 0.0);

        
        glActiveTexture(GL_TEXTURE0);
        glGenTextures(1, &outputTexture);
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        // This is necessary for non-power-of-two textures
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);

        glActiveTexture(GL_TEXTURE1);
        glGenFramebuffers(1, &defaultFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
        
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, backingWidth, backingHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, outputTexture, 0);
        
//        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
//        
//        NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", status);
        glBindTexture(GL_TEXTURE_2D, 0);
        
        imageVertices = malloc(sizeof(vertex_t) * imageMeshNumVertices);
        imageIndices = malloc(sizeof(GLuint) * imageMeshNumIndices);
        
        InitPlane(imageMeshWidth, imageMeshHeight, imageVertices, imageIndices);

        glGenBuffers(1, imageVerticeBuffer);
        GL_CHECK_ERR;
        glBindBuffer(GL_ARRAY_BUFFER, imageVerticeBuffer[0]);
        GL_CHECK_ERR;
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertex_t) * imageMeshNumVertices,
                     imageVertices, GL_DYNAMIC_DRAW);
        GL_CHECK_ERR;
        
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        
        glGenBuffers(1, imageIndexBuffer);
        GL_CHECK_ERR;
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, imageIndexBuffer[0]);
        GL_CHECK_ERR;
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(GLushort) * imageMeshNumIndices,
                     imageIndices, GL_STATIC_DRAW);
        GL_CHECK_ERR;
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
        
        videoCamera = [[GPUImageVideoCamera alloc] initWithSessionPreset:AVCaptureSessionPreset640x480 cameraPosition:AVCaptureDevicePositionFront];
        //videoCamera.outputImageOrientation = UIInterfaceOrientationPortrait;
        //videoCamera.outputImageOrientation = UIInterfaceOrientationLandscapeRight;
        //inputFilter = [[GPUImageSepiaFilter alloc] init];
        textureOutput = [[GPUImageTextureOutput alloc] init];
        textureOutput.delegate = self;
        
        [self convert3DTransform:&currentCalculatedMatrix toMatrix:currentModelViewMatrix];
        glkModelViewMatrix = GLKMatrix4MakeWithArray(currentModelViewMatrix);

        [videoCamera addTarget:textureOutput];
        //[inputFilter addTarget:textureOutput];
        
        CGRect screenRect = [[UIScreen mainScreen] bounds];
        screenWidth = screenRect.size.width;
        screenHeight = screenRect.size.height;
    }

    return self;
}

- (void)render
{
    if (!newFrameAvailableBlock)
    {
        return;
    }
    
    [EAGLContext setCurrentContext:context];
    
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
	
	//glEnable(GL_CULL_FACE);
	//glCullFace(GL_BACK);
    
    glViewport(0, 0, backingWidth, backingHeight);
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
	
    glUseProgram(program);
    
    glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, textureForCubeFace);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	
    // Update uniform value
	glUniform1i(uniforms[UNIFORM_TEXTURE], 4);
	glUniformMatrix4fv(uniforms[UNIFORM_MODELVIEWMATRIX], 1, 0, currentModelViewMatrix);
    
    // Update attribute values
    glBindBuffer(GL_ARRAY_BUFFER, imageVerticeBuffer[0]);
    GL_CHECK_ERR;
    glVertexAttribPointer(ATTRIB_VERTEX, 3, GL_FLOAT, GL_FALSE,
                          sizeof(vertex_t), (void*) offsetof(vertex_t,x));
    GL_CHECK_ERR;
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    GL_CHECK_ERR;
	glVertexAttribPointer(ATTRIB_TEXTUREPOSITION, 2, GL_FLOAT, GL_FALSE,
                          sizeof(vertex_t), (void*) offsetof(vertex_t,s0));
    GL_CHECK_ERR;
    glEnableVertexAttribArray(ATTRIB_TEXTUREPOSITION);
    GL_CHECK_ERR;
    glVertexAttribPointer(ATTRIB_DEFORM, 2, GL_FLOAT, GL_FALSE,
                          sizeof(vertex_t), (void*) offsetof(vertex_t,dx));
    GL_CHECK_ERR;
    glEnableVertexAttribArray(ATTRIB_DEFORM);
    GL_CHECK_ERR;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, imageIndexBuffer[0]);
    GL_CHECK_ERR;
    glDrawElements(GL_TRIANGLE_STRIP, imageMeshNumIndices, GL_UNSIGNED_SHORT,
     (void*) 0);
    /*
    glDrawElements(GL_LINE_STRIP, imageMeshNumIndices, GL_UNSIGNED_SHORT,
                   (void*) 0);
     */
    GL_CHECK_ERR;
    
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    
    // The flush is required at the end here to make sure the FBO texture is written to before passing it back to GPUImage
    glFlush();
    
	newFrameAvailableBlock();
}

- (void)autoHeal
{
    BOOL doneHealing = YES;
    int h = imageMeshHeight + 1;
    int w = imageMeshWidth + 1;
    int offset;
    const CGFloat step = 0.01;

    
    for (int y = 0; y < h; y++)
    {
        for (int x = 0; x < w; x++)
        {
            offset = y*(imageMeshWidth+1) + x;
            
            CGFloat dx = imageVertices[offset].dx;
            CGFloat dy = imageVertices[offset].dy;
            
            if(dx > step) {
                dx -= step;
            }
            
            if(dx < -step)
                dx += step;
            
            if(dy > step)
                dy -= step;
            
            if(dy < -step)
                dy += step;

            if(dx > step || dx < -step) {
                doneHealing = NO;
            } else {
                dx = 0.0;
            }
            
            if(dy > step || dy < -step) {
                doneHealing = NO;
            } else {
                dy = 0.0;
            }
            
            imageVertices[offset].dx = dx;
            imageVertices[offset].dy = dy;
        }
    }
    
    glBindBuffer(GL_ARRAY_BUFFER, imageVerticeBuffer[0]);
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(vertex_t) * imageMeshNumVertices, imageVertices);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    
    if(!doneHealing) {
        [self performSelector:@selector(autoHeal) withObject:nil afterDelay:0.05];
    }
}

- (void)startHealing
{
    assert([NSThread isMainThread]);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoHeal) object:nil];
    [self performSelector:@selector(autoHeal) withObject:nil afterDelay:3.0];
}

- (void)deformPointsFromCenter:(CGPoint)center toPoint:(CGPoint)point
{
    /*
    bool testResult;
    GLint viewport[4];
    glGetIntegerv(GL_VIEWPORT, viewport);

    //GLKVector3 nearPt;
    //GLKVector3 farPt;
    GLKVector3 touchPt;
    
    touchPt = GLKMathUnproject(GLKVector3Make(center.x, center.y, 0.0), glkModelViewMatrix, GLKMatrix4Identity, &viewport[0] , &testResult);
    //farPt = GLKMathUnproject(GLKVector3Make(center.x, center.y, 1.0), glkModelViewMatrix, GLKMatrix4Identity, &viewport[0] , &testResult);
    //farPt = GLKVector3Subtract(farPt, nearPt);
     
    GLfloat glCenterX = (touchPt.v[0] + 0.9)/0.8;
    GLfloat glCenterY = (touchPt.v[1] + 0.9)/0.8;
    
    touchPt = GLKMathUnproject(GLKVector3Make(point.x, point.y, 0.0), glkModelViewMatrix, GLKMatrix4Identity, &viewport[0] , &testResult);
    //farPt = GLKMathUnproject(GLKVector3Make(point.x, point.y, 1.0), glkModelViewMatrix, GLKMatrix4Identity, &viewport[0] , &testResult);
    //touchPt = GLKVector3Subtract(farPt, nearPt);
    
    
    GLfloat glPointX = (touchPt.v[0] + 0.9)/0.8;
    GLfloat glPointY = (touchPt.v[1] + 0.9)/0.8;
    //CGPoint midPoint;
     */
    GLfloat glCenterY = center.x / screenWidth;
    GLfloat glCenterX = center.y / screenHeight;
    GLfloat glPointY = point.x / screenWidth;
    GLfloat glPointX = point.y / screenHeight;
    
    int h = imageMeshHeight + 1;
    int w = imageMeshWidth + 1;
    int offset;
    for (int y = 0; y < h; y++)
    {
        for (int x = 0; x < w; x++)
        {
            offset = y*(imageMeshWidth+1) + x;
            
            CGFloat px = imageVertices[offset].x;
            CGFloat py = imageVertices[offset].y;
            
            GLfloat distX = glCenterX - px;
            GLfloat distY = glCenterY - py;
            GLfloat dist = sqrt(distX*distX + distY*distY);
            if(dist < 0.1) {
                imageVertices[offset].dx = (glPointY - glCenterY);
                imageVertices[offset].dy = (glPointX - glCenterX);
            }
            
            //if(x==1 && y==1)
            //    NSLog(@"(%d,%d) p(%.2f,%.2f) d(%.2f,%.2f) s(%.2f,%.2f,%.2f)", x, y, glPointX, glPointY, glPointX - glCenterX, glPointY - glCenterY, distX, distY,dist);
        }
    }
    glBindBuffer(GL_ARRAY_BUFFER, imageVerticeBuffer[0]);
    glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(vertex_t) * imageMeshNumVertices, imageVertices);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    
    [self startHealing];
}

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)file
{
    GLint status;
    const GLchar *source;

    source = (GLchar *)[[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] UTF8String];
    if (!source)
    {
        NSLog(@"Failed to load vertex shader");
        return FALSE;
    }

    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &source, NULL);
    glCompileShader(*shader);

#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(*shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif

    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0)
    {
        glDeleteShader(*shader);
        return FALSE;
    }

    return TRUE;
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;

    glLinkProgram(prog);

#if defined(DEBUG)
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif

    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0)
        return FALSE;

    return TRUE;
}

- (BOOL)validateProgram:(GLuint)prog
{
    GLint logLength, status;

    glValidateProgram(prog);
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program validate log:\n%s", log);
        free(log);
    }

    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == 0)
        return FALSE;

    return TRUE;
}

- (BOOL)loadShaders
{
    GLuint vertShader, fragShader;
    NSString *vertShaderPathname, *fragShaderPathname;

    // Create shader program
    program = glCreateProgram();

    // Create and compile vertex shader
    vertShaderPathname = [[NSBundle mainBundle] pathForResource:@"Shader" ofType:@"vsh"];
    if (![self compileShader:&vertShader type:GL_VERTEX_SHADER file:vertShaderPathname])
    {
        NSLog(@"Failed to compile vertex shader");
        return FALSE;
    }

    // Create and compile fragment shader
    fragShaderPathname = [[NSBundle mainBundle] pathForResource:@"Shader" ofType:@"fsh"];
    if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER file:fragShaderPathname])
    {
        NSLog(@"Failed to compile fragment shader");
        return FALSE;
    }

    // Attach vertex shader to program
    glAttachShader(program, vertShader);
    GL_CHECK_ERR;
    // Attach fragment shader to program
    glAttachShader(program, fragShader);
    GL_CHECK_ERR;
    // Bind attribute locations
    // this needs to be done prior to linking
    glBindAttribLocation(program, ATTRIB_VERTEX, "position");
    glBindAttribLocation(program, ATTRIB_TEXTUREPOSITION, "inputTextureCoordinate");
    glBindAttribLocation(program, ATTRIB_DEFORM, "deform");
    GL_CHECK_ERR;

    // Link program
    if (![self linkProgram:program])
    {
        NSLog(@"Failed to link program: %d", program);

        if (vertShader)
        {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader)
        {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (program)
        {
            glDeleteProgram(program);
            program = 0;
        }
        
        return FALSE;
    }

    // Get uniform locations
    uniforms[UNIFORM_MODELVIEWMATRIX] = glGetUniformLocation(program, "modelViewProjMatrix");
    uniforms[UNIFORM_TEXTURE] = glGetUniformLocation(program, "texture");

    // Release vertex and fragment shaders
    if (vertShader)
        glDeleteShader(vertShader);
    if (fragShader)
        glDeleteShader(fragShader);

    return TRUE;
}

- (void)dealloc
{
    // Tear down GL
    if (defaultFramebuffer)
    {
        glDeleteFramebuffers(1, &defaultFramebuffer);
        defaultFramebuffer = 0;
    }

    if (colorRenderbuffer)
    {
        glDeleteRenderbuffers(1, &colorRenderbuffer);
        colorRenderbuffer = 0;
    }

    if (program)
    {
        glDeleteProgram(program);
        program = 0;
    }

    // Tear down context
    if ([EAGLContext currentContext] == context)
        [EAGLContext setCurrentContext:nil];

    [context release];
    context = nil;

    [super dealloc];
}

- (void)convert3DTransform:(CATransform3D *)transform3D toMatrix:(GLfloat *)matrix;
{
	//	struct CATransform3D
	//	{
	//		CGFloat m11, m12, m13, m14;
	//		CGFloat m21, m22, m23, m24;
	//		CGFloat m31, m32, m33, m34;
	//		CGFloat m41, m42, m43, m44;
	//	};
	
	matrix[0] = (GLfloat)transform3D->m11;
	matrix[1] = (GLfloat)transform3D->m12;
	matrix[2] = (GLfloat)transform3D->m13;
	matrix[3] = (GLfloat)transform3D->m14;
	matrix[4] = (GLfloat)transform3D->m21;
	matrix[5] = (GLfloat)transform3D->m22;
	matrix[6] = (GLfloat)transform3D->m23;
	matrix[7] = (GLfloat)transform3D->m24;
	matrix[8] = (GLfloat)transform3D->m31;
	matrix[9] = (GLfloat)transform3D->m32;
	matrix[10] = (GLfloat)transform3D->m33;
	matrix[11] = (GLfloat)transform3D->m34;
	matrix[12] = (GLfloat)transform3D->m41;
	matrix[13] = (GLfloat)transform3D->m42;
	matrix[14] = (GLfloat)transform3D->m43;
	matrix[15] = (GLfloat)transform3D->m44;
}

- (void)startCameraCapture;
{
    [videoCamera startCameraCapture];
}

#pragma mark -
#pragma mark GPUImageTextureOutputDelegate delegate method

- (void)newFrameReadyFromTextureOutput:(GPUImageTextureOutput *)callbackTextureOutput;
{
    // Rotation in response to touch events is handled on the main thread, so to be safe we dispatch this on the main queue as well
    // Nominally, I should create a dispatch queue just for the rendering within this application, but not today
    dispatch_async(dispatch_get_main_queue(), ^{
        textureForCubeFace = callbackTextureOutput.texture;
        
        //[self renderByRotatingAroundX:0.0 rotatingAroundY:0.0];
        [self render];
    });
}

@end
