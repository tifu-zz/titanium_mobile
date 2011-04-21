/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2011 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */

package org.appcelerator.titanium.proxy;

import java.io.UnsupportedEncodingException;
import java.util.Arrays;

import org.appcelerator.kroll.KrollConverter;
import org.appcelerator.kroll.KrollDict;
import org.appcelerator.kroll.KrollInvocation;
import org.appcelerator.kroll.KrollModule;
import org.appcelerator.kroll.KrollProxy;
import org.appcelerator.kroll.KrollScriptableDict;
import org.appcelerator.kroll.annotations.Kroll;
import org.appcelerator.titanium.TiBlob;
import org.appcelerator.titanium.TiC;
import org.appcelerator.titanium.TiContext;
import org.appcelerator.titanium.util.Log;
import org.appcelerator.titanium.util.TiConfig;
import org.appcelerator.titanium.util.TiConvert;
import org.mozilla.javascript.Scriptable;

import ti.modules.titanium.TitaniumModule;
import ti.modules.titanium.codec.CodecModule;


@Kroll.proxy(creatableInModule=TitaniumModule.class)
public class BufferProxy extends KrollProxy
{
	private static final String LCAT = "BufferProxy";
	private static final boolean DBG = TiConfig.LOGD;

	private byte[] buffer;


	public BufferProxy(TiContext context)
	{
		super(context);
	}

	public BufferProxy(TiContext context, int bufferSize)
	{
		super(context);
		buffer = new byte[bufferSize];
	}

	public BufferProxy(TiContext context, byte[] existingBuffer)
	{
		super(context);
		buffer = existingBuffer;
	}

	// We need to handle the "raw" create call so Kroll doesn't convert
	// the passed in arguments to an array (they have a "length" attribute)
	@Override
	public Object handleCreate(KrollInvocation invocation, Object[] args)
	{
		this.createdInModule = (KrollModule) invocation.getProxy();
		if (args.length > 0 && args[0] instanceof Scriptable) {
			KrollDict dict = new KrollScriptableDict((Scriptable) args[0]);
			handleCreationDict(dict);
		} else {
			buffer = new byte[0];
		}
		return KrollConverter.getInstance().convertNative(invocation, this);
	}

	@Override
	public void handleCreationDict(KrollDict dict)
	{
		super.handleCreationDict(dict);

		int length = 0;
		Object lengthProperty = dict.get(TiC.PROPERTY_LENGTH);
		if(lengthProperty != null) {
			length = TiConvert.toInt(lengthProperty);
		}

		buffer = new byte[length];
		Object data = dict.get(TiC.PROPERTY_DATA);
		if (data instanceof Number) {
			encodeNumber((Number) data, dict);
		} else if (data instanceof String) {
			encodeString((String) data, dict);
		}
	}

	protected void encodeNumber(Number data, KrollDict dict)
	{
		String type = TiConvert.toString(dict, TiC.PROPERTY_TYPE);
		if (type == null) {
			throw new IllegalArgumentException("data is a Number, but no type was given");
		}

		if (buffer.length == 0) {
			buffer = new byte[CodecModule.getWidth(type)];
		}

		int byteOrder = CodecModule.getByteOrder(dict.get(TiC.PROPERTY_BYTE_ORDER));
		CodecModule.encodeNumber(data, type, buffer, 0, byteOrder);
	}

	protected void encodeString(String data, KrollDict dict)
	{
		String type = TiConvert.toString(dict, TiC.PROPERTY_TYPE);
		if (type == null) {
			type = CodecModule.CHARSET_UTF8;
		}

		String charset = CodecModule.getCharset(type);
		try {
			byte bytes[] = data.getBytes(charset);
			if (buffer.length == 0) {
				buffer = bytes;
			} else {
				System.arraycopy(bytes, 0, buffer, 0, bytes.length);
			}
		} catch (UnsupportedEncodingException e) {
			Log.w(LCAT, e.getMessage(), e);
			throw new IllegalArgumentException("Unsupported Encoding: " + charset);
		}
	}

	public byte[] getBuffer()
	{
		return buffer;
	}

	@Override
	public boolean has(Scriptable scope, int index)
	{
		return buffer.length < index;
	}

	@Override
	public Object get(Scriptable scope, int index)
	{
		return buffer[index] & 0xFF;
	}

	@Override
	public void set(Scriptable scope, int index, Object value)
	{
		if (value instanceof Number) {
			buffer[index] = ((Number)value).byteValue();
		} else {
			super.set(scope, index, value);
		}
	}

	protected byte[] copyOf(byte[] array, int newLength)
	{
		byte newArray[] = new byte[newLength];
		int length = newLength;
		if (length > array.length) {
			length = array.length;
		}
		System.arraycopy(array, 0, newArray, 0, length);
		return newArray;
	}

	protected byte[] copyOfRange(byte[] array, int from, int to)
	{
		int length = to - from;
		byte newArray[] = new byte[length];
		System.arraycopy(array, from, newArray, 0, length);
		return newArray;
	}

	protected void validateOffsetAndLength(int offset, int length, int bufferLength)
	{
		if (length > offset + bufferLength) {
			throw new IllegalArgumentException("offset of " + offset + " and length of " + length + " is larger than the buffer length: " + bufferLength);
		}
	}

	@Kroll.method
	public int append(Object[] args)
	{
		int destLength = buffer.length;
		BufferProxy src = (BufferProxy) args[0];
		byte[] sourceBuffer = src.getBuffer();

		int offset = 0;
		if (args.length > 1 && args[1] != null) {
			offset = TiConvert.toInt(args[1]);
		}

		int sourceLength = sourceBuffer.length;
		if (args.length > 2 && args[2] != null) {
			sourceLength = TiConvert.toInt(args[2]);
		}

		validateOffsetAndLength(offset, sourceLength, sourceBuffer.length);

		buffer = copyOf(buffer, (destLength + sourceLength));
		System.arraycopy(sourceBuffer, offset, buffer, destLength, sourceLength);
		return sourceLength;
	}

	@Kroll.method
	public int insert(Object[] args)
	{
		if (args.length < 2) {
			throw new IllegalArgumentException("At least 2 arguments required for insert: src, offset");
		}
		BufferProxy sourceBufferProxy = (BufferProxy) args[0];
		byte[] sourceBuffer = sourceBufferProxy.getBuffer();
		int offset = TiConvert.toInt(args[1]);

		int sourceOffset = 0;
		if (args.length > 2 && args[2] != null) {
			sourceOffset = TiConvert.toInt(args[2]);
		}

		int sourceLength = sourceBuffer.length;
		if (args.length > 3 && args[3] != null) {
			sourceLength = TiConvert.toInt(args[3]);
		}

		validateOffsetAndLength(sourceOffset, sourceLength, sourceBuffer.length);

		byte[] preInsertBuffer = copyOf(buffer, offset);
		byte[] postInsertBuffer = copyOfRange(buffer, offset, buffer.length);

		buffer = new byte[(preInsertBuffer.length + sourceLength + postInsertBuffer.length)];
		System.arraycopy(preInsertBuffer, 0, buffer, 0, preInsertBuffer.length);
		System.arraycopy(sourceBuffer, sourceOffset, buffer, preInsertBuffer.length, sourceLength);
		System.arraycopy(postInsertBuffer, 0, buffer, (preInsertBuffer.length + sourceLength), postInsertBuffer.length);

		return sourceLength;
	}

	@Kroll.method
	public int copy(Object[] args)
	{
		if (args.length < 1) {
			throw new IllegalArgumentException("At least 1 argument required for copy: srcBuffer");
		}

		BufferProxy sourceBufferProxy = (BufferProxy) args[0];
		byte[] sourceBuffer = sourceBufferProxy.getBuffer();

		int offset = 0;
		if (args.length > 1 && args[1] != null) {
			offset = TiConvert.toInt(args[1]);
		}

		int sourceOffset = 0;
		if (args.length > 2 && args[2] != null) {
			sourceOffset = TiConvert.toInt(args[2]);
		}

		int sourceLength = sourceBuffer.length;
		if (args.length > 3 && args[3] != null) {
			sourceLength = TiConvert.toInt(args[3]);
		}

		validateOffsetAndLength(sourceOffset, sourceLength, sourceBuffer.length);

		System.arraycopy(sourceBuffer, sourceOffset, buffer, offset, sourceLength);
		return sourceLength;
	}

	@Kroll.method
	public BufferProxy clone(Object[] args)
	{
		int offset = 0;
		if (args.length > 0 && args[0] != null) {
			offset = TiConvert.toInt(args[0]);
		}

		int length = buffer.length;
		if (args.length > 1 && args[1] != null) {
			length = TiConvert.toInt(args[1]);
		}

		validateOffsetAndLength(offset, length, buffer.length);

		return new BufferProxy(context, copyOfRange(buffer, offset, offset+length));
	}

	@Kroll.method
	public void fill(Object[] args)
	{
		if (args.length < 1) {
			throw new IllegalArgumentException("fill requires at least 1 argument: fillByte");
		}

		int fillByte = TiConvert.toInt(args[0]);
		int offset = 0;
		if (args.length > 1 && args[1] != null) {
			offset = TiConvert.toInt(args[1]);
		}

		int length = buffer.length;
		if (args.length > 2 && args[2] != null) {
			length = TiConvert.toInt(args[2]);
		}

		validateOffsetAndLength(offset, length, buffer.length);

		Arrays.fill(buffer, offset, (offset + length), (byte)fillByte);
	}

	@Kroll.method
	public boolean clear()
	{
		Arrays.fill(buffer, (byte)0);
		return true;
	}

	@Kroll.method
	public boolean release()
	{
		buffer = new byte[0];
		return true;
	}

	public String toString()
	{
		return new String(buffer);
	}

	@Kroll.method
	public TiBlob toBlob()
	{
		return TiBlob.blobFromData(context, buffer);
	}

	@Kroll.getProperty @Kroll.method
	public int getLength()
	{
		return buffer.length;
	}

	@Kroll.setProperty @Kroll.method
	public void setLength(int length)
	{
		resize(length);
	}

	public void resize(int length)
	{
		buffer = copyOf(buffer, length);
	}
}

