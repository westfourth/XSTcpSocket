//
//  XSTcpSocket.h
//  XSTcpSocket
//
//  Created by xisi on 15/5/15.
//  Copyright (c) 2015年 inspur. All rights reserved.
//

#import <Foundation/Foundation.h>

//#if TARGET_IPHONE_SIMULATOR
#if 0
    #define XSSocketLog(format, ...)      NSLog(@"___XSTcpSocket " format, ##__VA_ARGS__)
#else
    #define XSSocketLog(format, ...)
#endif

//  socket发送、接收缓冲区大小
#define XSTcpSocketSendRecvBufferSize           1 << 15

extern NSString *const XSTcpSocketErrorDomain;          //!<  错误域

//! socket状态
typedef NS_ENUM(NSInteger, XSTcpSocketState) {
    XSTcpSocketStateClosed = 0,         //!<  关闭
    XSTcpSocketStateOpen,               //!<  打开
    XSTcpSocketStateConnecting,         //!<  正在连接
    XSTcpSocketStateConnected,          //!<  已经连接
    XSTcpSocketStateConnectFailed,      //!<  连接失败
};


/*!
    @brief  客户端socket，基于CFSocket。全部为异步模式
 
    @warning    外面请慎用多线程并行模式。
 */
@interface XSTcpSocket : NSObject {
    @package
    dispatch_queue_t _recvQueue;                //!<  串行线程，主要用于接收数据
    dispatch_queue_t _sendQueue;                //!<  串行线程，主要用于发送数据
    CFSocketRef _socket;
}

@property (weak) id delegate;                   //!<  委托（请在connect前设置）
@property (readonly) XSTcpSocketState state;    //!<  socket状态

//! 打开。（!!!使用之前一定要打开）
- (void)open;

//! 关闭socket，停止其RunLoop，释放所有相关的资源。（!!!不会做任何回调）
- (void)close;

/*!
    @brief  连接到指定地址＋端口号。（每次连接如果没有open会自动open）
 
    @warning    ---------------------------------------------------------
                每次连接前，都需要open；（如果之前已经open，则需要close，再open）
                ---------------------------------------------------------

    @param  hostname    主机。IP地址／域名
    @param  port        端口号。例如：80、http
    @param  timeout     如果为负值，则立即返回，并且让socket在后台运行。
 */
- (void)connectToHost:(NSString *)hostname port:(NSString *)port timeout:(NSTimeInterval)timeout;

/*!
    @brief  发送数据。
 
    @param  data    要发送的数据
    @param  timeout 超时
 */
- (void)sendData:(NSData *)data timeout:(NSTimeInterval)timeout;

@end


#pragma mark -  XSTcpSocketDelegate
//_______________________________________________________________________________________________________________
@protocol XSTcpSocketDelegate <NSObject>
@optional

//! 连接成功
- (void)socket:(XSTcpSocket *)socket didConnectToIpAddress:(NSString *)address port:(uint16_t)port;

//! 连接失败
- (void)socket:(XSTcpSocket *)socket connectFailWithError:(NSError *)error;

//! 连接断开（这里指对方主动断开连接）
- (void)socketDidClose:(XSTcpSocket *)socket;

//! 发送失败
- (void)socket:(XSTcpSocket *)socket sendData:(NSData *)data failWithError:(NSError *)error;

//! 接收数据
- (void)socket:(XSTcpSocket *)socket didReceivedData:(NSData *)data;

//! 可以写入
- (void)socketCanWrite:(XSTcpSocket *)socket;

@end