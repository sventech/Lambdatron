//
//  readerforms.swift
//  Lambdatron
//
//  Created by Austin Zheng on 11/17/14.
//  Copyright (c) 2014 Austin Zheng. All rights reserved.
//

import Foundation

/// An enum describing all the reader forms recognized by the interpreter
enum ReaderForm : Printable {
  case Quote
  case SyntaxQuote
  case Unquote
  case UnquoteSplice
  
  var description : String {
    switch self {
    case Quote: return "q*"
    case SyntaxQuote: return "syntax-quote*"
    case Unquote: return "unquote*"
    case UnquoteSplice: return "unquote-splice*"
    }
  }
}

extension Cons {
  
  var isSyntaxQuote : Bool {
    if let readerForm = self.asReaderForm() {
      switch readerForm {
      case .SyntaxQuote: return true
      default: return false
      }
    }
    return false
  }

  // NOTE: this is ONLY called when `(a1 a2 a3 a4) is evaluated, when a_n is a list. This method determines whether
  //  or not this is a normal list, or a special item.
  // e.g. `(~a ...), which is actually `((~ a) ...); a_n would be the (~ a) sub-list (NOT the overall list being
  // syntax-quoted)
  func expansionForSyntaxQuote() -> ConsValue {
    if let readerForm = self.asReaderForm() {
      // This list represents a reader macro call
      if let nextValue = next?.value {
        switch readerForm {
        case .Quote:
          // `('a ...) -> `((list `'a) ...)
          let quotedValue = nextValue.expandQuotedItem().expandSyntaxQuotedItem()
          return .ListLiteral(Cons(.Symbol("list"), next: Cons(quotedValue)))
        case .SyntaxQuote:
          // `(`a ...) --> `(`(list `a) ...)
          let quotedValue = nextValue.expandSyntaxQuotedItem()
          let f = quotedValue.expandSyntaxQuotedItem()
          return .ListLiteral(Cons(ConsValue.Symbol("list"), next: Cons(f)))
        case .Unquote:
          // `(~a ...) --> `((list a) ...)
          return .ListLiteral(Cons(.Symbol("list"), next: Cons(nextValue)))
        case .UnquoteSplice:
          // `(~@a ...) --> `(a ...)
          return nextValue
        }
      }
      fatal("Something is wrong...(reader form without an arg)")
    }
    else {
      // This list is a normal list, recursively syntax-quote it further
      // `(a ...) --> `((list `a) ...)
      if isEmpty {
        return .ListLiteral(Cons(.Symbol("list")))
      }
      let result = ConsValue.ListLiteral(self).expandSyntaxQuotedItem()
      let listAppendedWithResult = ConsValue.ListLiteral(Cons(.Symbol("list"), next: Cons(result)))
      return listAppendedWithResult
    }
  }
  
}

extension ConsValue {
  
  var isNone : Bool {
    switch self {
    case .None: return true
    default: return false
    }
  }
  
  // NOTE: This will be the top-level reader expansion method
  func readerExpand() -> ConsValue {
    switch self {
    case NilLiteral, BoolLiteral, NumberLiteral, StringLiteral, Symbol, Special:
      return self
    case let ListLiteral(l):
      // Only if the list literal is encapsulating a reader macro form does anything happen
      // CASE 1: The list itself is a reader macro (e.g. (` X), (~ X))
      if let readerForm = l.asReaderForm() {
        if let next = l.next {
          switch readerForm {
          case .Quote:
            return next.value.expandQuotedItem()
          case .SyntaxQuote:
            return next.value.expandSyntaxQuotedItem()
          case .Unquote:
            return next.value
          case .UnquoteSplice:
            // Not allowed
            fatal("Cannot invoke unquote-splice outside the context of a seq")
          }
        }
        fatal("Cannot invoke a reader form without a single argument")
      }
      // CASE 2: The list is NOT a reader macro invocation, and contains one or more items (e.g. (a1 a2 a3))
      var head : Cons? = l
      while let actualHead = head {
        actualHead.value = actualHead.value.readerExpand()
        head = actualHead.next
      }
      return self
    case let VectorLiteral(v):
      if v.count == 0 {
        return self
      }
      var copy : Vector = v
      for var i=0; i<v.count; i++ {
        copy[i] = v[i].readerExpand()
      }
      return .VectorLiteral(copy)
    case FunctionLiteral, ReaderMacro, None, RecurSentinel, MacroArgument:
      fatal("Something has gone very wrong in ConsValue's readerExpand method")
    }
  }
  
  // If we are expanding an expression (' a), we call this method on 'a'; it'll give us back (quote a)
  func expandQuotedItem() -> ConsValue {
    // Expanding (' a) always results in (quote a)
    let expansion : ConsValue = {
      switch self {
      case let .ListLiteral(l) where !l.isEmpty:
        if let readerForm = l.asReaderForm() {
          if let next = l.next {
            switch readerForm {
            case .Quote:
              return next.value.expandQuotedItem()
            case .SyntaxQuote:
              return next.value.expandSyntaxQuotedItem().expandQuotedItem()
            case .Unquote:
              return next.value
            case .UnquoteSplice:
              // Not allowed
              fatal("Cannot invoke unquote-splice outside the context of a seq")
            }
          }
          fatal("Cannot invoke reader form without any arguments")
        }
        return self
      default:
        return self
      }
    }()
    return .ListLiteral(Cons(.Special(.Quote), next: Cons(expansion)))
  }
  
  // If we are expanding an expression (` a), we call this method on 'a'; it'll give us back (seq (concat a))
  func expandSyntaxQuotedItem() -> ConsValue {
    // ` differs in behavior depending on exactly what a is; it is most complex when a is a sequence
    switch self {
    case NilLiteral, BoolLiteral, NumberLiteral, StringLiteral:
      // Expanding (` LIT) always results in LIT
      return self
    case Symbol, Special:
      // Expanding (` a) results in (quote a)
      return .ListLiteral(Cons(.Special(.Quote), next: Cons(self)))
    case let ListLiteral(l):
      // We have a list, such that we have (` (a b c d e))
      // We need to reader-expand each individual a, b, c, then wrap it all in a (seq (cons X))
      // Collect all the values
      if l.isEmpty {
        // `() --> (list)
        return .ListLiteral(Cons(.Symbol("list")))
      }
      // CASE 1: The list itself is a reader macro (e.g. (` X), (~ X))
      if let readerForm = l.asReaderForm() {
        if let next = l.next {
          switch readerForm {
          case .Quote:
            return next.value.expandQuotedItem().expandSyntaxQuotedItem()
          case .SyntaxQuote:
            return next.value.expandSyntaxQuotedItem().expandSyntaxQuotedItem()
          case .Unquote:
            return next.value
          case .UnquoteSplice:
            // Not allowed
            fatal("Cannot invoke unquote-splice outside the context of a seq")
          }
        }
        fatal("Cannot invoke reader form without any arguments")
      }
      
      // CASE 2: The list is NOT a reader macro invocation, and contains one or more items (e.g. (a1 a2 a3))
      let symbols = Cons.collectSymbols(l)
      var expansionBuffer : [ConsValue] = []
      for symbol in symbols {
        switch symbol {
        case NilLiteral, BoolLiteral, NumberLiteral, StringLiteral, Symbol, Special:
          // A literal or symbol in the list is recursively syntax-quoted
          let expanded = symbol.expandSyntaxQuotedItem()
          expansionBuffer.append(.ListLiteral(Cons(.Symbol("list"), next: Cons(expanded))))
        case let ListLiteral(symbolAsList):
          // A 'list' in the list could represent a normal list or a nested reader macro
          expansionBuffer.append(symbolAsList.expansionForSyntaxQuote())
        case let VectorLiteral(symbolAsVector):
          expansionBuffer.append(.ListLiteral(Cons(.Symbol("list"), next: Cons(symbol.expandSyntaxQuotedItem()))))
        case FunctionLiteral, ReaderMacro, None, RecurSentinel, MacroArgument:
          fatal("Something has gone very wrong 2")
        }
      }
      // Create the seq-concat list
      let concatHead = Cons(.Symbol("concat"))
      var this = concatHead
      for bufferItem in expansionBuffer {
        let next = Cons(bufferItem)
        this.next = next
        this = next
      }
      let seqHead = Cons(.Symbol("seq"), next: Cons(.ListLiteral(concatHead)))
      return .ListLiteral(seqHead)
    case let VectorLiteral(v):
      let asList = Cons(.ReaderMacro(.SyntaxQuote), next: Cons(.ListLiteral(Cons.listFromVector(v))))
      let expanded = ConsValue.ListLiteral(asList).readerExpand()
      let head = Cons(.Symbol("apply"), next: Cons(.Symbol("vector"), next: Cons(expanded)))
      return .ListLiteral(head)
    case FunctionLiteral:
      fatal("Cannot expand a syntax-quoted function literal")
    case ReaderMacro:
      fatal("Cannot expand a syntax-quoted reader macro")
    case None:
      fatal("Cannot expand a syntax-quoted None token")
    case RecurSentinel:
      fatal("Cannot expand a syntax-quoted recur sentinel")
    case MacroArgument:
      fatal("Cannot expand a syntax-quoted macro argument")
    }
  }
}