/**
 * Appcelerator Titanium Mobile
 * Copyright (c) 2009-2011 by Appcelerator, Inc. All Rights Reserved.
 * Licensed under the terms of the Apache Public License
 * Please see the LICENSE included with this distribution for details.
 */
#ifdef USE_TI_NETWORKSOCKET
#import "TiNetworkSocketTCPProxy.h"
#import "NetworkModule.h"
#import "TiBlob.h"
#import "TiBuffer.h"

static NSString* SOCK_KEY = @"socket";
static NSString* ARG_KEY = @"arg";

@interface TiNetworkSocketTCPProxy (Private)
-(void)cleanupSocket;
-(void)setConnectedSocket:(AsyncSocket*)sock;
-(void)startConnectingSocket;
-(void)startListeningSocket;
-(void)startAcceptedSocket:(NSDictionary*)info;
-(void)socketRunLoop;
@end

@implementation TiNetworkSocketTCPProxy
@synthesize host, connected, accepted, closed, error;

#pragma mark Internals

-(id)init
{
    if (self = [super init]) {
        listening = [[NSCondition alloc] init];
        ioCondition = [[NSCondition alloc] init];
        internalState = SOCKET_INITIALIZED;
        socketThread = nil;
        acceptArgs = [[NSMutableDictionary alloc] init];
        acceptCondition = [[NSCondition alloc] init];
        operationInfo = [[NSMutableDictionary alloc] init];
        asynchTagCount = 0;
    }
    return self;
}

-(void)dealloc
{
    // Calls _destroy
    [super dealloc];
}

-(void)_destroy
{
    [listening lock];
    [listening broadcast];
    [listening unlock];
    
    [ioCondition lock];
    [ioCondition broadcast];
    [ioCondition unlock];

    [acceptCondition lock];
    [acceptCondition broadcast];
    [acceptCondition unlock];
    
    internalState = SOCKET_CLOSED;
    // Socket cleanup, if necessary
    if ([socketThread isExecuting]) {
        [self performSelector:@selector(cleanupSocket) onThread:socketThread withObject:nil waitUntilDone:YES];
    }

    RELEASE_TO_NIL(operationInfo);
    RELEASE_TO_NIL(acceptArgs);
    
    RELEASE_TO_NIL(connected);
    RELEASE_TO_NIL(accepted);
    RELEASE_TO_NIL(closed);
    RELEASE_TO_NIL(error);
    
    // Release the conditions... but is this safe enough?
    RELEASE_TO_NIL(listening);
    RELEASE_TO_NIL(ioCondition);
    RELEASE_TO_NIL(acceptCondition);
    
    RELEASE_TO_NIL(host);
    
    [super _destroy];
}

-(void)cleanupSocket
{
    [socket disconnect];
    [socket setDelegate:nil];
    RELEASE_TO_NIL(socket);
}

-(void)setConnectedSocket:(AsyncSocket*)sock
{
    [self cleanupSocket];
    internalState = SOCKET_CONNECTED;
    socket = [sock retain];
    [socket setDelegate:self];
    socketThread = [NSThread currentThread];
}

#define AUTORELEASE_LOOP 5
-(void)socketRunLoop
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    [socketThread setName:[NSString stringWithFormat:@"Ti.Network.Socket.TCP (%x)",self]];
    // Begin the run loop for the socket
    int counter=0;
    while (!(internalState & (SOCKET_CLOSED | SOCKET_ERROR)) &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]) 
    {
        if (++counter == AUTORELEASE_LOOP) {
            [pool release];
            pool = [[NSAutoreleasePool alloc] init];
            counter = 0;
        }
    }
    // No longer send messages to this thread!
    socketThread = nil;
    
    [pool release];
}

-(void)startConnectingSocket
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    id port = [self valueForUndefinedKey:@"port"]; // Can be string or int
    NSNumber* timeout = [self valueForUndefinedKey:@"timeout"];
    
    if (host == nil || [host isEqual:@""]) {
        // TODO: MASSIVE: FIX OUR BROKEN EXCEPTION HANDLING
        /*
        [self throwException:@"Attempt to connect with bad host: nil or empty"
                   subreason:nil
                    location:CODELOCATION];
         */
        NSLog(@"[ERROR] Attempt to connect with bad host: nil or empty");
        [pool release];
        return;
    }
    
    socket = [[AsyncSocket alloc] initWithDelegate:self];
    socketThread = [NSThread currentThread];
    
    NSError* err = nil;
    BOOL success;
    if (timeout == nil) {
        success = [socket connectToHost:host onPort:[TiUtils intValue:port] error:&err];
    }
    else {
        success = [socket connectToHost:host onPort:[port intValue] withTimeout:[timeout doubleValue] error:&err];
    }
    
    if (err || !success) {
        [self cleanupSocket];
        internalState = SOCKET_ERROR;
        
        /*
        [self throwException:[NSString stringWithFormat:@"Connection attempt error: %@",(err ? err : @"UNKNOWN ERROR")]
                   subreason:nil
                    location:CODELOCATION];
         */
        NSLog(@"[ERROR] Connection attempt error: %@", (err ? err : @"UNKNOWN ERROR"));
        [pool release];
        return;
    }
    
    [self socketRunLoop];
    
    [pool release];
}

-(void)startListeningSocket
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    id port = [self valueForKey:@"port"]; // Can be string or int
    
    if (host == nil || [host isEqual:@""]) {
        /*
        [self throwException:@"Attempt to listen with bad host: nil or empty"
                   subreason:nil
                    location:CODELOCATION];
         */
        NSLog(@"[ERROR] Attempt to listen with bad host: nil or empty");
        [pool release];
        return;       
    }
    
    socket = [[AsyncSocket alloc] initWithDelegate:self];
        
    NSError* err = nil;
    BOOL success = [socket acceptOnInterface:host port:[port intValue] autoaccept:NO error:&err];
    
    if (err || !success) {
        [self cleanupSocket];
        internalState = SOCKET_ERROR;
        
        [listening lock];
        [listening signal];
        [listening unlock];
        
        /*
        [self throwException:[NSString stringWithFormat:@"Listening attempt error: %@",(err ? err : @"<UNKNOWN ERROR>")]
                   subreason:nil
                    location:CODELOCATION];
         */
        NSLog(@"[ERROR] Listening attempt error: %@", (err ? err : @"UNKNOWN ERROR"));
        [pool release];
        return;
    }
    // Make sure that we 'accept' only when explicitly requested
    CFSocketRef cfSocket = [socket getCFSocket];
    CFOptionFlags options = CFSocketGetSocketFlags(cfSocket);
    CFSocketSetSocketFlags(cfSocket, options & ~kCFSocketAutomaticallyReenableAcceptCallBack);
  
    socketThread = [NSThread currentThread];
    
    [listening lock];
    internalState = SOCKET_LISTENING;
    [listening signal];
    [listening unlock];
    
    [self socketRunLoop];
    
    [pool release];
}

-(void)startAcceptedSocket:(NSDictionary*)info
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

    // Here's a goofy pattern in sockets; because we may _destroy on the Kroll thread while other threads (i.e. sockets, or newly created thread)
    // is blocking, we need to hold on to the conditions we wait on, and then release them once we're done with them. Introduces some extra
    // overhead, but it probably prevents DUMB CRASHES from happening.
    
    NSCondition* tempConditionRef = [acceptCondition retain];
    [tempConditionRef lock];
    acceptRunLoop = [NSRunLoop currentRunLoop];
    [tempConditionRef signal];
    [tempConditionRef wait];
    [tempConditionRef unlock];
    [tempConditionRef release];
    
    NSArray* arg = [info objectForKey:ARG_KEY];
    AsyncSocket* newSocket = [info objectForKey:SOCK_KEY];
    
    TiNetworkSocketTCPProxy* proxy = [[[TiNetworkSocketTCPProxy alloc] _initWithPageContext:[self executionContext] args:arg] autorelease];
    [proxy setConnectedSocket:newSocket];
    
    // TODO: remoteHost/remotePort & host/port?
    [proxy setValue:[newSocket connectedHost] forKey:@"host"];
    [proxy setValue:NUMINT([newSocket connectedPort]) forKey:@"port"];
    
    if (accepted != nil) {
        NSDictionary* event = [NSDictionary dictionaryWithObjectsAndKeys:self,@"socket",proxy,@"inbound",nil];
        [self _fireEventToListener:@"accepted" withObject:event listener:accepted thisObject:self];
    }

    [proxy socketRunLoop];
    
    [pool release];
}

#pragma mark Public API : Functions

// Used to bump API calls onto the socket thread if necessary
#define ENSURE_SOCKET_THREAD(f,x) \
if (socketThread == nil) { \
return; \
} \
if ([NSThread currentThread] != socketThread) { \
[self performSelector:@selector(f:) onThread:socketThread withObject:x waitUntilDone:YES]; \
return; \
} \

// Convenience for io waits
#define SAFE_WAIT(condition) \
{\
NSCondition* temp = [condition retain]; \
[temp lock]; \
[temp wait]; \
[temp unlock]; \
[temp release]; \
}\


-(void)connect:(id)_void
{
    if (!(internalState & SOCKET_INITIALIZED)) {
        /*
        [self throwException:[NSString stringWithFormat:@"Attempt to connect with bad state: %d",internalState]
                   subreason:nil 
                    location:CODELOCATION];
         */
        NSLog(@"[ERROR] Attempt to connect with bad state: %d", internalState);
        return;
    }
    
    [self performSelectorInBackground:@selector(startConnectingSocket) withObject:nil];
}

// TODO: Can we actually implement the max queue size...?
-(void)listen:(id)arg
{
    if (!(internalState & SOCKET_INITIALIZED)) {
        /*
        [self throwException:[NSString stringWithFormat:@"Attempt to listen with bad state: %d", internalState]
                   subreason:nil
                    location:CODELOCATION];
         */
        NSLog(@"[ERROR] Attempt to listen with bad state: %d", internalState);
        return;
    }
    
    [self performSelectorInBackground:@selector(startListeningSocket) withObject:nil];
    
    // Call should block until we're listening or have an error
    NSCondition* tempConditionRef = [listening retain];
    [tempConditionRef lock];
    if (!(internalState & (SOCKET_LISTENING | SOCKET_ERROR))) {
        [tempConditionRef wait];
    }
    [tempConditionRef unlock];
    [tempConditionRef release];
}

-(void)accept:(id)arg
{
    // Only change the accept args if we have an accept in progress
    // TODO: Probably want a lock for this...
    if (accepting) {
        [acceptArgs setValue:arg forKey:ARG_KEY];
        return;
    }
    
    ENSURE_SOCKET_THREAD(accept,arg);
    NSDictionary* args = nil;
    ENSURE_ARG_OR_NIL_AT_INDEX(args, arg, 0, NSDictionary);
    [acceptArgs setValue:arg forKey:ARG_KEY];
    
    CFSocketRef sock = [socket getCFSocket];
    CFSocketEnableCallBacks(sock, kCFSocketAcceptCallBack);
    accepting = YES;
}

-(void)close:(id)_void
{
    // TODO: Signal everything under the sun & close
    // TODO: If the socket is ALREADY closed, we don't need to go to the thread...
    // TODO: Need to make sure the socket thread isn't == nil
    ENSURE_SOCKET_THREAD(close,_void);
    
    if (!(internalState & (SOCKET_CONNECTED | SOCKET_LISTENING | SOCKET_INITIALIZED))) {
        /*
        [self throwException:[NSString stringWithFormat:@"Attempt to close in invalid state: %d",internalState]
                   subreason:nil
                    location:CODELOCATION];
         */
        NSLog(@"Attempt to close in invalid state: %d", internalState);
        return;
    }
    
    [self cleanupSocket];
}

#pragma mark Public API : Properties

-(NSNumber*)state
{
    return NUMINT(internalState);
}

// TODO: Move to TiBase?
#define TYPESAFE_SETTER(funcname,prop,type) \
-(void)funcname:(type*)val \
{ \
ENSURE_TYPE_OR_NIL(val,type); \
if (prop != val) { \
[prop release]; \
prop = [val retain]; \
}\
}

TYPESAFE_SETTER(setHost, host, NSString)

TYPESAFE_SETTER(setConnected, connected, KrollCallback)
TYPESAFE_SETTER(setAccepted, accepted, KrollCallback)
TYPESAFE_SETTER(setClosed, closed, KrollCallback)
TYPESAFE_SETTER(setError, error, KrollCallback)

#pragma mark TiStreamInternal implementations

-(NSNumber*)isReadable:(id)_void
{
    return NUMBOOL(internalState & SOCKET_CONNECTED);
}

-(NSNumber*)isWritable:(id)_void
{
    return NUMBOOL(internalState & SOCKET_CONNECTED);
}

-(int)readToBuffer:(TiBuffer*)buffer offset:(int)offset length:(int)length callback:(KrollCallback *)callback
{
    // As always, ensure that operations take place on the socket thread...
    if ([NSThread currentThread] != socketThread) {
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(readToBuffer:offset:length:callback:)]];
        [invocation setTarget:self];
        [invocation setSelector:@selector(readToBuffer:offset:length:callback:)];
        [invocation setArgument:&buffer atIndex:2];
        [invocation setArgument:&offset atIndex:3];
        [invocation setArgument:&length atIndex:4];
        [invocation setArgument:&callback atIndex:5];
        [invocation retainArguments];
        
        [invocation performSelector:@selector(invoke) onThread:socketThread withObject:nil waitUntilDone:NO];
        
        if (callback == nil) {
            SAFE_WAIT(ioCondition);
        }
        
        return readDataLength;
    }
    else {
        int tag = -1;
        if (callback != nil) {
            tag = asynchTagCount;
            NSDictionary* asynchInfo = [NSDictionary dictionaryWithObjectsAndKeys:buffer,@"buffer",callback,@"callback",NUMINT(TO_BUFFER),@"type",nil];
            [operationInfo setObject:asynchInfo forKey:NUMINT(tag)];
            asynchTagCount = (asynchTagCount + 1) % INT_MAX;
        }
        
        [socket readDataWithTimeout:-1
                             buffer:[buffer data]
                       bufferOffset:offset
                          maxLength:length
                                tag:tag];
    }
    
    return 0; // Bogus return value; the real value is returned when we finish the read
}

-(int)writeFromBuffer:(TiBuffer*)buffer offset:(int)offset length:(int)length callback:(KrollCallback *)callback
{
    // As always, ensure that operations take place on the socket thread...
    if ([NSThread currentThread] != socketThread) {
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(writeFromBuffer:offset:length:callback:)]];
        [invocation setTarget:self];
        [invocation setSelector:@selector(writeFromBuffer:offset:length:callback:)];
        [invocation setArgument:&buffer atIndex:2];
        [invocation setArgument:&offset atIndex:3];
        [invocation setArgument:&length atIndex:4];
        [invocation setArgument:&callback atIndex:5];
        [invocation retainArguments];
        
        [invocation performSelector:@selector(invoke) onThread:socketThread withObject:nil waitUntilDone:NO];
        
        if (callback == nil) {
            SAFE_WAIT(ioCondition);
        }
        
        int result = 0;
        [invocation getReturnValue:&result];
        
        return result;
    }
    else {
        NSData* subdata = [[buffer data] subdataWithRange:NSMakeRange(offset, length)];
        int tag = -1;
        if (callback != nil) {
            tag = asynchTagCount;
            NSDictionary* asynchInfo = [NSDictionary dictionaryWithObjectsAndKeys:NUMINT([subdata length]),@"bytesProcessed",callback,@"callback", nil];
            [operationInfo setObject:asynchInfo forKey:NUMINT(tag)];
            asynchTagCount = (asynchTagCount + 1) % INT_MAX;
        }
        [socket writeData:subdata withTimeout:-1 tag:tag];
        
        return [subdata length];
    }
}

-(int)writeToStream:(id<TiStreamInternal>)output chunkSize:(int)size callback:(KrollCallback *)callback
{
    if ([NSThread currentThread] != socketThread) {
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(writeToStream:chunkSize:callback:)]];
        [invocation setTarget:self];
        [invocation setSelector:@selector(writeToStream:chunkSize:callback:)];
        [invocation setArgument:&output atIndex:2];
        [invocation setArgument:&size atIndex:3];
        [invocation setArgument:&callback atIndex:4];
        [invocation performSelector:@selector(invoke) onThread:socketThread withObject:nil waitUntilDone:NO];
        [invocation retainArguments];
        
        if (callback == nil) {
            SAFE_WAIT(ioCondition);
        }
        
        return readDataLength;
    }
    else {
        int tag = asynchTagCount;
        NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:output,@"destination",NUMINT(size),@"chunkSize",callback,@"callback",NUMINT(TO_STREAM),@"type", nil];
        [operationInfo setObject:info forKey:NUMINT(tag)];
        asynchTagCount = (asynchTagCount + 1) % INT_MAX;
        
        [socket readDataWithTimeout:-1
                             buffer:nil
                       bufferOffset:0
                          maxLength:size
                                tag:tag];
        
        return readDataLength;
    }
}

-(void)pumpToCallback:(KrollCallback *)callback chunkSize:(int)size asynch:(BOOL)asynch
{
    if ([NSThread currentThread] != socketThread) {
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(pumpToCallback:chunkSize:asynch:)]];
        [invocation setTarget:self];
        [invocation setSelector:@selector(pumpToCallback:chunkSize:asynch:)];
        [invocation setArgument:&callback atIndex:2];
        [invocation setArgument:&size atIndex:3];
        [invocation setArgument:&asynch atIndex:4];
        [invocation performSelector:@selector(invoke) onThread:socketThread withObject:nil waitUntilDone:NO];
        [invocation retainArguments];
        
        if (!asynch) {
            SAFE_WAIT(ioCondition);
        }
    }
    else {
        int tag = asynchTagCount;
        NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:NUMINT(size),@"chunkSize",callback,@"callback",NUMINT(TO_CALLBACK),@"type", nil];
        [operationInfo setObject:info forKey:NUMINT(tag)];
        asynchTagCount = (asynchTagCount + 1) % INT_MAX;
        
        [socket readDataWithTimeout:-1
                             buffer:nil
                       bufferOffset:0
                          maxLength:size
                                tag:tag];
    }    
}

#pragma mark AsyncSocketDelegate methods

-(void)onSocket:(AsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port
{
    // This gets called for sockets created via accepting, so return if the connected socket is NOT us
    if (sock != socket) {
        return;
    }

    internalState = SOCKET_CONNECTED;
    
    if (connected != nil) {
        NSDictionary* event = [NSDictionary dictionaryWithObjectsAndKeys:self,@"socket",nil];
        [self _fireEventToListener:@"connected" withObject:event listener:connected thisObject:self];        
    }
 }

-(void)onSocketDidDisconnect:(AsyncSocket *)sock
{
    // Triggered when we error out, so don't fire in that situation
    if (!(internalState & SOCKET_ERROR)) {
        // May also be triggered when we're already "closed"
        if (!(internalState & SOCKET_CLOSED)) {
            internalState = SOCKET_CLOSED;
            if (closed != nil) {
                NSDictionary* event = [NSDictionary dictionaryWithObjectsAndKeys:self,@"socket", nil];
                [self _fireEventToListener:@"closed" withObject:event listener:closed thisObject:self];
            }
        }
    }
    
    // Signal any waiting I/O
    // TODO: Be sure to handle any signal on closing
    [ioCondition lock];
    [ioCondition signal];
    [ioCondition unlock];
}

-(NSRunLoop*)onSocket:(AsyncSocket *)sock wantsRunLoopForNewSocket:(AsyncSocket *)newSocket
{
    // We start up the accepted socket thread, and wait for the run loop to be cached, and return it...
    NSCondition* tempConditionRef = [acceptCondition retain];
    [tempConditionRef lock];
    if (acceptRunLoop == nil) {
        [tempConditionRef wait];
    }
    [tempConditionRef signal];
    [tempConditionRef unlock];
    [tempConditionRef release];
    
    return acceptRunLoop;
}

- (void)onSocket:(AsyncSocket *)sock didAcceptNewSocket:(AsyncSocket *)newSocket
{
    [acceptArgs setValue:newSocket forKey:SOCK_KEY];
    [self performSelectorInBackground:@selector(startAcceptedSocket:) withObject:acceptArgs];
    accepting = NO;
}

// TODO: As per AsyncSocket docs, may want to call "unreadData" and return that information, or at least allow access to it via some other method
-(void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)err
{
    internalState = SOCKET_ERROR;
    if (error != nil) {
        NSDictionary* event = [NSDictionary dictionaryWithObjectsAndKeys:self,@"socket",NUMINT([err code]),@"errorCode",[err localizedDescription],@"error",nil];
        [self _fireEventToListener:@"error" withObject:event listener:error thisObject:self];
    }
}

-(void)onSocket:(AsyncSocket *)sock didWriteDataWithTag:(long)tag 
{

    // Result of asynch write
    if (tag > -1) {
        NSDictionary* info = [operationInfo objectForKey:NUMINT(tag)];
        KrollCallback* callback = [info valueForKey:@"callback"];
        
        NSDictionary* event = [NSDictionary dictionaryWithObjectsAndKeys:[info valueForKey:@"bytesProcessed"],@"bytesProcessed",nil];
        [self _fireEventToListener:@"write" withObject:event listener:callback thisObject:self];
        [operationInfo removeObjectForKey:NUMINT(tag)];
    } 
    else {
        // Signal the IO condition
        [ioCondition lock];
        [ioCondition signal];
        [ioCondition unlock];
    }
}

// 'Read' can also lead to a writeStream/pump operation
-(void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    // We do NOT SIGNAL I/O if dealing with a tagged operation. The reason why? Because toStream/pump need to keep streaming and pumping...
    // until the socket is closed, which fires the I/O condition signal.
    
    // Specialized operation
    if (tag > -1) {
        NSDictionary* info = [operationInfo objectForKey:NUMINT(tag)];
        ReadDestination type = [[info objectForKey:@"type"] intValue];
        switch (type) {
            case TO_BUFFER: {
                KrollCallback* callback = [info valueForKey:@"callback"];
                TiBuffer* buffer = [info valueForKey:@"buffer"];
                
                NSDictionary* event = [NSDictionary dictionaryWithObjectsAndKeys:buffer,@"buffer",NUMINT([data length]),@"bytesProcessed", nil];
                [self _fireEventToListener:@"read" withObject:event listener:callback thisObject:self];
                break;
            }
            case TO_STREAM: {
                // Perform the write to stream
                id<TiStreamInternal> stream = [info valueForKey:@"destination"];
                int size = [TiUtils intValue:[info valueForKey:@"chunkSize"]];
                KrollCallback* callback = [info valueForKey:@"callback"];
                
                TiBuffer* tempBuffer = [[[TiBuffer alloc] _initWithPageContext:[self executionContext]] autorelease];
                [tempBuffer setData:[NSMutableData dataWithData:data]];
                readDataLength += [data length];
                
                // TODO: We need to be able to monitor this stream for write errors, and then report back via an exception or the callback or whatever
                [stream writeFromBuffer:tempBuffer offset:0 length:[data length] callback:nil];
                
                // ... And then set up the next read to it.
                [self writeToStream:stream chunkSize:size callback:callback];
                break;
            }
            case TO_CALLBACK: {
                // Perform the pump to callback
                KrollCallback* callback = [info valueForKey:@"callback"];
                int size = [TiUtils intValue:[info valueForKey:@"chunkSize"]];
                
                TiBuffer* tempBuffer = [[[TiBuffer alloc] _initWithPageContext:[self executionContext]] autorelease];
                [tempBuffer setData:[NSMutableData dataWithData:data]];
                readDataLength += [data length];
                
                NSDictionary* event = [NSDictionary dictionaryWithObjectsAndKeys:self,@"source",tempBuffer,@"buffer",NUMINT([data length]),@"bytesProcessed",NUMINT(readDataLength),@"totalBytesProcessed", nil];
                [self _fireEventToListener:@"pump" withObject:event listener:callback thisObject:nil];
                
                // ... And queue up the next pump.
                [self pumpToCallback:callback chunkSize:size asynch:YES]; // Only consider the 1st pump "synchronous", that's the one which blocks!
                break;
            }
        }
        [operationInfo removeObjectForKey:NUMINT(tag)];
    }
    else {
        // Only signal the condition for your standard blocking read
        // The amount of data read is available only off of this 'data' object... not off the initial buffer we passed.
        [ioCondition lock];
        readDataLength = [data length];
        [ioCondition signal];
        [ioCondition unlock];
    }
}

@end
#endif