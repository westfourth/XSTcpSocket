//
//  XSTcpSocket.m
//  XSTcpSocket
//
//  Created by xisi on 15/5/15.
//  Copyright (c) 2015年 inspur. All rights reserved.
//

#import "XSTcpSocket.h"
#import <sys/socket.h>
#import <arpa/inet.h>
#import <netdb.h>

NSString *const XSTcpSocketErrorDomain = @"XSTcpSocketErrorDomain";

@implementation XSTcpSocket

- (id)init {
    XSSocketLog(@"%s", __func__);
    self = [super init];
    if (self) {
        _recvQueue = dispatch_queue_create("com.xisi.socket.tcp.recv", DISPATCH_QUEUE_SERIAL);
        _sendQueue = dispatch_queue_create("com.xisi.socket.tcp.send", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

//! 打开
- (void)open {
    XSSocketLog(@"%s", __func__);
    void *info = (__bridge_retained void *)(self);
    CFSocketContext context = {0, info, NULL, NULL, NULL};
    _socket = CFSocketCreate(kCFAllocatorDefault,
                             PF_UNSPEC,             //  IPv4 + IPv6
                             SOCK_STREAM,           //
                             IPPROTO_TCP,           //  TCP
                             kCFSocketDataCallBack | kCFSocketConnectCallBack | kCFSocketWriteCallBack,
                             socketCallBack,
                             &context);
    
    [self setSocketOptions];
    
    /*
         RunLoop防止当前线程结束
         连接失败时，该RunLoop会退出
     */
    CFRunLoopSourceRef runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);
    dispatch_async(_recvQueue, ^{
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopDefaultMode);
        _state = XSTcpSocketStateOpen;
        CFRelease(runLoopSource);
        CFRunLoopRun();
        CFRelease(info);
    });
}

//! 关闭socket，会释放所有相关的资源。（不会回调）
- (void)close {
    XSSocketLog(@"%s", __func__);
    if (_socket == 0) {                 //  没有CFSocketCreate创建的时候，不能使用CFSocketInvalidate
        return;
    }
    CFSocketInvalidate(_socket);        //  结束当前RunLoop
    _state = XSTcpSocketStateClosed;
}

//! 设置socket缓冲区大小
- (void)setSocketOptions {
    CFSocketRef socketRef = _socket;
    CFSocketNativeHandle sock = CFSocketGetNative(socketRef);
    
    /*
     接收/发送缓冲区都为32K
     */
    int result = 0;
    int bufferSize = XSTcpSocketSendRecvBufferSize;
    //    socklen_t sockOptSize = sizeof(bufferSize);
    
    result = setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &bufferSize, sizeof(bufferSize));
    if (result < 0) {
        perror(">>> 设置发送缓冲区大小失败");
    }
    
    result = setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufferSize, sizeof(bufferSize));
    if (result < 0) {
        perror(">>> 设置接收缓冲区大小失败");
    }
}

//! 连接到指定地址＋端口号
- (void)connectToHost:(NSString *)hostname port:(NSString *)port timeout:(NSTimeInterval)timeout {
    XSSocketLog(@"%s", __func__);
    dispatch_async(_sendQueue, ^{
        struct addrinfo hints, *res, *res0;
        CFSocketError sockError = kCFSocketError;
        
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = PF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        
        int errorCode = getaddrinfo(hostname.UTF8String, port.UTF8String, &hints, &res0);
        if (errorCode) {
            XSSocketLog(@">>> 域名解析失败：%s", gai_strerror(errorCode));
            return;
        }
        
        for (res = res0; res; res = res->ai_next) {
            CFDataRef addressData = CFDataCreate(kCFAllocatorDefault, (unsigned char *)res->ai_addr, res->ai_addrlen);
            
            _state = XSTcpSocketStateConnecting;
            //  如果timeout为负值，则工作在非阻塞模式
            sockError = CFSocketConnectToAddress(_socket, addressData, timeout);
            
            CFRelease(addressData);
            if (sockError == kCFSocketSuccess) {
                break;                      //  连接成功，不再继续连接
            }
        }
        freeaddrinfo(res0);
        
        /*
             各种没有回调情况
                 1.  没有网            kCFSocketError          ENETUNREACH
                 2.  4G               kCFSocketTimeout
                 3.  服务端没有启动     kCFSocketError          不确定
         */
        
        if (sockError != kCFSocketSuccess) {
            _state = XSTcpSocketStateConnectFailed;
            NSString *str;
            int code;
            if (sockError == kCFSocketTimeout) {
                str = @"连接超时";
                code = ETIME;
            } else {
                str = [NSString stringWithFormat:@"连接失败: %s", strerror(errno)];
                code = errno;
            }
            NSDictionary *infoDict = @{NSLocalizedDescriptionKey: str};
            NSError *error = [NSError errorWithDomain:XSTcpSocketErrorDomain code:code userInfo:infoDict];
            
            if (self.delegate && [self.delegate respondsToSelector:@selector(socket:connectFailWithError:)]) {
                [self.delegate socket:self connectFailWithError:error];
            }
        } else {
            _state = XSTcpSocketStateConnected;
        }
    });
}

//! 发送数据
- (void)sendData:(NSData *)data timeout:(NSTimeInterval)timeout {
    XSSocketLog(@"%s", __func__);
    if (data.length == 0) {        
        return;
    }
    dispatch_async(_sendQueue, ^{
        NSString *errorStr;
        CFDataRef addressData = CFSocketCopyPeerAddress(_socket);
        if (addressData == NULL) {
            errorStr = @"未连接";
            NSDictionary *infoDict = @{NSLocalizedDescriptionKey: errorStr};
            NSError *error = [NSError errorWithDomain:XSTcpSocketErrorDomain code:ENOTCONN userInfo:infoDict];
            if (self.delegate && [self.delegate respondsToSelector:@selector(socket:sendData:failWithError:)]) {
                [self.delegate socket:self sendData:data failWithError:error];
            }
            return;
        }
        CFRelease(addressData);
        
        //  timeout 只有在 “>0” 的情况下才有用
        CFSocketError sockError = CFSocketSendData(_socket, NULL, (__bridge CFDataRef)data, timeout);
        /*
            利用阻塞模式，当发送完数据后，socket就可以继续写入
         */
        if (self.delegate && [self.delegate respondsToSelector:@selector(socketCanWrite:)]) {
            [self.delegate socketCanWrite:self];
        }
        
        //  判断是否发送成功
        if (sockError != kCFSocketSuccess) {
            int code;
            if (sockError == kCFSocketTimeout) {
                errorStr = @"发送超时";
                code = ETIME;
            } else {
                errorStr = [NSString stringWithFormat:@"发送失败: %s", strerror(errno)];
                code = errno;
            }
            NSDictionary *infoDict = @{NSLocalizedDescriptionKey: errorStr};
            NSError *error = [NSError errorWithDomain:XSTcpSocketErrorDomain code:code userInfo:infoDict];
            
            if (self.delegate && [self.delegate respondsToSelector:@selector(socket:sendData:failWithError:)]) {
                [self.delegate socket:self sendData:data failWithError:error];
            }
        }
    });
}

#pragma mark -  回调
//_______________________________________________________________________________________________________________

void socketCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    XSSocketLog(@"%s", __func__);
    XSTcpSocket *tcpSocket = (__bridge XSTcpSocket *)(info);
    
    switch (type) {
        case kCFSocketDataCallBack: {
            XSSocketLog(@"kCFSocketDataCallBack");
            NSData *recvData = (__bridge NSData *)(data);
            if ([recvData isKindOfClass:[NSData class]]) {
                if (recvData.length == 0) {         //  如果数据为'0 bytes'时，表示服务端关闭socket
                    tcpSocket->_state = XSTcpSocketStateClosed;
                    if (tcpSocket.delegate && [tcpSocket.delegate respondsToSelector:@selector(socketDidClose:)]) {
                        [tcpSocket.delegate socketDidClose:tcpSocket];
                    }
                } else {                            //  接收到数据
                    if (tcpSocket.delegate && [tcpSocket.delegate respondsToSelector:@selector(socket:didReceivedData:)]) {
                        [tcpSocket.delegate socket:tcpSocket didReceivedData:recvData];
                    }
                }

            }
        }
            break;
        case kCFSocketConnectCallBack: {
            XSSocketLog(@"kCFSocketConnectCallBack");
            CFDataRef addressData = CFSocketCopyPeerAddress(s);
            if (addressData != NULL) {           //  取到服务器地址，表示连接成功
                struct sockaddr_in *serverAddr = (struct sockaddr_in *)CFDataGetBytePtr(addressData);
                char *addr = inet_ntoa(serverAddr->sin_addr);
                uint16_t port = ntohs(serverAddr->sin_port);
                NSString *addressStr = [[NSString alloc] initWithUTF8String:addr];
                CFRelease(addressData);
                tcpSocket->_state = XSTcpSocketStateConnected;
                
                if (tcpSocket.delegate && [tcpSocket.delegate respondsToSelector:@selector(socket:didConnectToIpAddress:port:)]) {
                    [tcpSocket.delegate socket:tcpSocket didConnectToIpAddress:addressStr port:port];
                }
            }
        }
            break;
        case kCFSocketWriteCallBack:
            XSSocketLog(@"kCFSocketWriteCallBack");
            if (tcpSocket.delegate && [tcpSocket.delegate respondsToSelector:@selector(socketCanWrite:)]) {
                [tcpSocket.delegate socketCanWrite:tcpSocket];
            }
            break;
        default:
            [NSException raise:@"XSTcpSocket未处理回调类型" format:@"CFSocketCallBackType = %ld", type];
            break;
    }
}

@end