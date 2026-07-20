//
//  MessagePackParser.h
//  Fetch TV Remote
//
//  Created by Chris Hulbert on 23/06/11.
//  Copyright 2011 Digital Five. All rights reserved.
//

#import <Foundation/Foundation.h>

// Vendored for MessagePackSwift benchmarks: the streaming category (and its
// msgpack_unpacker ivar) is omitted so this public header stays Foundation-only.
@interface MessagePackParser : NSObject

+ (id)parseData:(NSData*)data;

@end
