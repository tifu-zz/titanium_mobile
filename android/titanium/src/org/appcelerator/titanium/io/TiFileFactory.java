/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2009-2010 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */
package org.appcelerator.titanium.io;

import java.io.File;

import org.appcelerator.titanium.TiC;
import org.appcelerator.titanium.TiContext;
import org.appcelerator.titanium.util.Log;
import org.appcelerator.titanium.util.TiConfig;
import org.appcelerator.titanium.util.TiFileHelper;

import android.net.Uri;

public class TiFileFactory
{
	private static final String LCAT = "TiFileFactory";
	private static final boolean DBG = TiConfig.LOGD;

	public static TiBaseFile createTitaniumFile(TiContext tiContext, String path, boolean stream)
	{
		String[] parts = { path };
		return createTitaniumFile(tiContext, parts, stream);
	}

	public static TiBaseFile createTitaniumFile(
		TiContext tiContext, String[] parts, boolean stream)
	{
		TiBaseFile file = null;

		String initial = parts[0];
		if (DBG) {
			Log.d(LCAT,"getting initial from parts: " + initial);
		}

		if (initial.startsWith("app://")) {
			String path = initial.substring(6);
			path = formPath(path,parts);
			file = new TiResourceFile(tiContext, path);
		} else if (initial.startsWith(TiC.URL_ANDROID_ASSET_RESOURCES)) {
			String path = initial.substring(32);
			path = formPath(path,parts);
			file = new TiResourceFile(tiContext, path);
		} else if (initial.startsWith("appdata://")) {
			String path = initial.substring(10);
			path = formPath(path,parts);
			if (path != null && path.length() > 0 && path.charAt(0)=='/')
			{
				path = path.substring(1);
			}
			File f = new File(getDataDirectory(tiContext, false),path);
			file = new TiFile(tiContext, f,"appdata://"+path, stream);
		} else if (initial.startsWith("appdata-private://")) {
			String path = initial.substring(18);
			path = formPath(path,parts);
			File f = new File(getDataDirectory(tiContext, true),path);
			file = new TiFile(tiContext, f,"appdata-private://"+path, stream);
		} else if (initial.startsWith("file://")) {
			String path = initial.substring(7);
			path = formPath(path, parts);
			file = new TiFile(tiContext, new File(path), "file://" + path, stream);
		} else if (initial.startsWith("content://")) {
			String path = initial.substring(10);
			path = formPath(path, parts);
			file = new TitaniumBlob(tiContext, "content://" + path);
		} else if (initial.startsWith("/")) {
			String path = "";

			path = formPath(path, insertBefore(path,parts));
			file = new TiFile(tiContext, new File(path), "file://" + path, stream);
		} else {
			String path = "";
			path = formPath(path,insertBefore(path,parts));
			File f = new File(getDataDirectory(tiContext, true),path);
			file = new TiFile(tiContext, f,"appdata-private://"+path, stream);
		}

		return file;
	}

	private static String[] insertBefore(String path, String[] parts) {
		String[] p = new String[parts.length + 1];
		p[0] = path;
		for(int i = 0; i < parts.length; i++) {
			p[i+1] = parts[i];
		}
		return p;
	}

	private static String formPath(String path, String parts[])
	{
		if (!path.endsWith("/") && path.length() > 0 && parts.length > 1)
		{
			path+="/";
		}
		for (int c=1;c<parts.length;c++)
		{
			String part = parts[c];
			path += part;
			if (c+1<parts.length && !part.endsWith("/"))
			{
				path+="/";
			}
		}
		return path;
	}

	public static File getDataDirectory (TiContext tiContext, boolean privateStorage)
	{
		TiFileHelper tfh = new TiFileHelper(tiContext.getTiApp());
		return tfh.getDataDirectory(privateStorage);
	}

	public static boolean isLocalScheme(String url)
	{
		Uri uri = Uri.parse(url);
		String scheme = uri.getScheme();

		if (scheme == null) {
			return true;
		}

		scheme = scheme.toLowerCase();
		if ("app".equals(scheme) || "appdata".equals(scheme) || "appdata-private".equals(scheme) ||
			"file".equals(scheme) || "content".equals(scheme))
		{
			return true;
		}

		return false;
	}

}
