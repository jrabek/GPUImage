attribute vec4 position;
attribute vec2 deform;
attribute vec4 inputTextureCoordinate;

varying vec2 textureCoordinate;

uniform mat4 modelViewProjMatrix;

void main()
{
    gl_Position = modelViewProjMatrix * position;
    gl_Position.xy = gl_Position.xy + deform.xy;
	textureCoordinate = inputTextureCoordinate.xy;
}
