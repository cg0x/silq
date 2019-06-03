// Written in the D programming language
// License: http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0

import std.array,std.algorithm,std.range;
import std.format, std.conv, std.typecons:Q=Tuple,q=tuple;
import lexer,scope_,expression,type,declaration,error,util;

alias CommaExp=BinaryExp!(Tok!",");
alias AssignExp=BinaryExp!(Tok!"←");
alias OrAssignExp=BinaryExp!(Tok!"||←");
alias AndAssignExp=BinaryExp!(Tok!"&&←");
alias AddAssignExp=BinaryExp!(Tok!"+←");
alias SubAssignExp=BinaryExp!(Tok!"-←");
alias MulAssignExp=BinaryExp!(Tok!"·←");
alias DivAssignExp=BinaryExp!(Tok!"/←");
alias IDivAssignExp=BinaryExp!(Tok!"div←");
alias ModAssignExp=BinaryExp!(Tok!"%←");
alias PowAssignExp=BinaryExp!(Tok!"^←");
alias CatAssignExp=BinaryExp!(Tok!"~←");
alias BitOrAssignExp=BinaryExp!(Tok!"∨←");
alias BitXorAssignExp=BinaryExp!(Tok!"⊕←");
alias BitAndAssignExp=BinaryExp!(Tok!"∧←");
alias AddExp=BinaryExp!(Tok!"+");
alias SubExp=BinaryExp!(Tok!"-");
alias NSubExp=BinaryExp!(Tok!"sub");
alias MulExp=BinaryExp!(Tok!"·");
alias DivExp=BinaryExp!(Tok!"/");
alias IDivExp=BinaryExp!(Tok!"div");
alias ModExp=BinaryExp!(Tok!"%");
alias PowExp=BinaryExp!(Tok!"^");
alias CatExp=BinaryExp!(Tok!"~");
alias BitOrExp=BinaryExp!(Tok!"∨");
alias BitXorExp=BinaryExp!(Tok!"⊕");
alias BitAndExp=BinaryExp!(Tok!"∧");
alias UMinusExp=UnaryExp!(Tok!"-");
alias UNotExp=UnaryExp!(Tok!"¬");
alias UBitNotExp=UnaryExp!(Tok!"~");
alias LtExp=BinaryExp!(Tok!"<");
alias LeExp=BinaryExp!(Tok!"≤");
alias GtExp=BinaryExp!(Tok!">");
alias GeExp=BinaryExp!(Tok!"≥");
alias EqExp=BinaryExp!(Tok!"=");
alias NeqExp=BinaryExp!(Tok!"≠");
alias OrExp=BinaryExp!(Tok!"||");
alias AndExp=BinaryExp!(Tok!"&&");
alias Exp=Expression;

void propErr(Expression e1,Expression e2){
	if(e1.sstate==SemState.error) e2.sstate=SemState.error;
}

DataScope isInDataScope(Scope sc){
	auto asc=cast(AggregateScope)sc;
	if(asc) return cast(DataScope)asc.parent;
	return null;
}

AggregateTy isDataTyId(Expression e){
	if(auto ce=cast(CallExp)e)
		return isDataTyId(ce.e);
	if(auto id=cast(Identifier)e)
		if(auto decl=cast(DatDecl)id.meaning)
			return decl.dtype;
	if(auto fe=cast(FieldExp)e)
		if(auto decl=cast(DatDecl)fe.f.meaning)
			return decl.dtype;
	return null;
}

void declareParameters(P)(Expression parent,bool isSquare,P[] params,Scope sc)if(is(P==Parameter)||is(P==DatParameter)){
	foreach(ref p;params){
		if(!p.dtype){ // !ℝ is the default parameter type for () and * is the default parameter type for []
			if(isSquare){
				auto id=New!Identifier("*");
				id.loc=p.loc;
				p.dtype=id;
			}else{
				auto id=New!Identifier(isSquare?"*":"ℝ");
				id.loc=p.loc;
				p.dtype=New!(UnaryExp!(Tok!"!"))(id);
				p.dtype.loc=p.loc;
			}
		}
		p=cast(P)varDeclSemantic(p,sc);
		assert(!!p);
		propErr(p,parent);
	}
}

VarDecl addVar(string name,Expression ty,Location loc,Scope sc){
	auto id=new Identifier(name);
	id.loc=loc;
	auto var=new VarDecl(id);
	var.loc=loc;
	var.vtype=ty;
	var=varDeclSemantic(var,sc);
	assert(!!var && var.sstate==SemState.completed);
	return var;
}
Expression presemantic(Declaration expr,Scope sc){
	bool success=true; // dummy
	if(!expr.scope_) makeDeclaration(expr,success,sc);
	if(auto dat=cast(DatDecl)expr){
		if(dat.dtype) return expr;
		auto dsc=new DataScope(sc,dat);
		assert(!dat.dscope_);
		dat.dscope_=dsc;
		dat.dtype=new AggregateTy(dat,!dat.isQuantum);
		if(dat.hasParams) declareParameters(dat,true,dat.params,dsc);
		if(!dat.body_.ascope_) dat.body_.ascope_=new AggregateScope(dat.dscope_);
		if(cast(NestedScope)sc) dat.context = addVar("`outer",contextTy(true),dat.loc,dsc);
		foreach(ref exp;dat.body_.s) exp=makeDeclaration(exp,success,dat.body_.ascope_);
		foreach(ref exp;dat.body_.s) if(auto decl=cast(Declaration)exp) exp=presemantic(decl,dat.body_.ascope_);
	}
	if(auto fd=cast(FunctionDef)expr){
		if(fd.fscope_) return fd;
		auto fsc=new FunctionScope(sc,fd);
		fd.type=unit;
		fd.fscope_=fsc;
		declareParameters(fd,fd.isSquare,fd.params,fsc); // parameter variables
		if(fd.rret){
			bool[] pc;
			string[] pn;
			Expression[] pty;
			foreach(p;fd.params){
				if(!p.vtype){
					assert(fd.sstate==SemState.error);
					return fd;
				}
				pc~=p.isConst;
				pn~=p.getName;
				pty~=p.vtype;
			}
			fd.ret=typeSemantic(fd.rret,fsc);
			assert(fd.isTuple||pty.length==1);
			auto pt=fd.isTuple?tupleTy(pty):pty[0];
			if(!fd.ret) fd.sstate=SemState.error;
			else fd.ftype=productTy(pc,pn,pt,fd.ret,fd.isSquare,fd.isTuple,fd.annotation,true);
			if(!fd.body_) return expr;
		}
		if(!fd.body_){
			sc.error("function without body should have a return type annotation",fd.loc);
			fd.sstate=SemState.error;
			return expr;
		}
		assert(!fd.body_.blscope_);
		fd.body_.blscope_=new BlockScope(fsc);
		if(auto dsc=isInDataScope(sc)){
			auto id=new Identifier(dsc.decl.name.name);
			id.loc=dsc.decl.loc;
			id.meaning=dsc.decl;
			id=cast(Identifier)expressionSemantic(id,sc,ConstResult.no);
			assert(!!id);
			Expression ctxty=id;
			if(dsc.decl.hasParams){
				auto args=dsc.decl.params.map!((p){
					auto id=new Identifier(p.name.name);
					id.meaning=p;
					auto r=expressionSemantic(id,sc,ConstResult.no);
					assert(r.sstate==SemState.completed);
					return r;
				}).array;
				assert(dsc.decl.isTuple||args.length==1);
				ctxty=callSemantic(new CallExp(ctxty,dsc.decl.isTuple?new TupleExp(args):args[0],true,false),sc,ConstResult.no);
				ctxty.sstate=SemState.completed;
				assert(ctxty.type == typeTy);
			}
			if(dsc.decl.name.name==fd.name.name){
				assert(!!fd.body_.blscope_);
				auto thisVar=addVar("this",ctxty,fd.loc,fd.body_.blscope_); // the 'this' variable
				fd.isConstructor=true;
				if(fd.rret){
					sc.error("constructor cannot have return type annotation",fd.loc);
					fd.sstate=SemState.error;
				}else{
					assert(dsc.decl.dtype);
					fd.ret=ctxty;
				}
				if(!fd.body_.s.length||!cast(ReturnExp)fd.body_.s[$-1]){
					auto thisid=new Identifier(thisVar.getName);
					thisid.loc=fd.loc;
					thisid.scope_=fd.body_.blscope_;
					thisid.meaning=thisVar;
					thisid.type=ctxty;
					thisid.sstate=SemState.completed;
					auto rete=new ReturnExp(thisid);
					rete.loc=thisid.loc;
					rete.sstate=SemState.completed;
					fd.body_.s~=rete;
				}
				if(dsc.decl.context){
					fd.context=dsc.decl.context; // TODO: ok?
					fd.contextVal=dsc.decl.context; // TODO: ok?
				}
				fd.thisVar=thisVar;
			}else{
				fd.contextVal=addVar("this",unit,fd.loc,fsc); // the 'this' value
				assert(!!fd.body_.blscope_);
				fd.context=addVar("this",ctxty,fd.loc,fd.body_.blscope_);
			}
			assert(dsc.decl.dtype);
		}else if(auto nsc=cast(NestedScope)sc){
			fd.contextVal=addVar("`outer",contextTy(true),fd.loc,fsc); // TODO: replace contextTy by suitable record type; make name 'outer' available
			fd.context=fd.contextVal;
		}
	}
	return expr;
}

import std.typecons: tuple,Tuple;
static Tuple!(Expression[],TopScope)[string] modules;
int importModule(string path,ErrorHandler err,out Expression[] exprs,out TopScope sc,Location loc=Location.init){
	if(path in modules){
		auto exprssc=modules[path];
		exprs=exprssc[0],sc=exprssc[1];
		if(!sc){
			if(loc.line) err.error("circular imports not supported",loc);
			else stderr.writeln("error: circular imports not supported",loc);
			return 1;
		}
		return 0;
	}
	modules[path]=tuple(Expression[].init,TopScope.init);
	scope(success) modules[path]=tuple(exprs,sc);
	TopScope prsc=null;
	Expression[] prelude;
	import parser;
	if(!prsc && path != preludePath())
		if(auto r=importModule(preludePath,err,prelude,prsc))
			return r;
	if(auto r=parseFile(getActualPath(path),err,exprs,loc))
		return r;
	sc=new TopScope(err);
	if(prsc) sc.import_(prsc);
	int nerr=err.nerrors;
	exprs=semantic(exprs,sc);
	return nerr!=err.nerrors;
}

Expression makeDeclaration(Expression expr,ref bool success,Scope sc){
	if(auto imp=cast(ImportExp)expr){
		imp.scope_ = sc;
		auto ctsc=cast(TopScope)sc;
		if(!ctsc){
			sc.error("nested imports not supported",imp.loc);
			imp.sstate=SemState.error;
			return imp;
		}
		foreach(p;imp.e){
			auto path = getActualPath(ImportExp.getPath(p));
			Expression[] exprs;
			TopScope tsc;
			if(importModule(path,sc.handler,exprs,tsc,imp.loc))
				imp.sstate=SemState.error;
			if(tsc) ctsc.import_(tsc);
		}
		if(imp.sstate!=SemState.error) imp.sstate=SemState.completed;
		return imp;
	}
	if(auto decl=cast(Declaration)expr){
		if(!decl.scope_) success&=sc.insert(decl);
		return decl;
	}
	if(auto ce=cast(CommaExp)expr){
		ce.e1=makeDeclaration(ce.e1,success,sc);
		propErr(ce.e1,ce);
		ce.e2=makeDeclaration(ce.e2,success,sc);
		propErr(ce.e2,ce);
		return ce;
	}
	if(auto be=cast(BinaryExp!(Tok!":="))expr){
		if(auto id=cast(Identifier)be.e1){
			auto nid=new Identifier(id.name);
			nid.loc=id.loc;
			auto vd=new VarDecl(nid);
			vd.loc=id.loc;
			success&=sc.insert(vd);
			id.name=vd.getName;
			id.scope_=sc;
			auto de=new SingleDefExp(vd,be);
			de.loc=be.loc;
			propErr(vd,de);
			return de;
		}else if(auto tpl=cast(TupleExp)be.e1){
			VarDecl[] vds;
			foreach(exp;tpl.e){
				auto id=cast(Identifier)exp;
				if(!id) goto LnoIdTuple;
				auto nid=new Identifier(id.name);
				nid.loc=id.loc;
				vds~=new VarDecl(nid);
				vds[$-1].loc=id.loc;
				success&=sc.insert(vds[$-1]);
				id.name=vds[$-1].getName;
				id.scope_=sc;
			}
			auto de=new MultiDefExp(vds,be);
			de.loc=be.loc;
			foreach(vd;vds) propErr(vd,de);
			return de;
		}else LnoIdTuple:{
			sc.error("left-hand side of definition must be identifier or tuple of identifiers",expr.loc);
			success=false;
		}
		success&=expr.sstate==SemState.completed;
		return expr;
	}
	if(auto tae=cast(TypeAnnotationExp)expr){
		if(auto id=cast(Identifier)tae.e){
			auto vd=new VarDecl(id);
			vd.loc=tae.loc;
			vd.dtype=tae.t;
			vd.vtype=typeSemantic(vd.dtype,sc);
			vd.loc=id.loc;
			success&=sc.insert(vd);
			id.name=vd.getName;
			id.scope_=sc;
			return vd;
		}
	}
	sc.error("not a declaration: "~expr.toString()~" ",expr.loc);
	expr.sstate=SemState.error;
	success=false;
	return expr;
}

void checkNotLinear(Expression e,Scope sc){
	if(sc.allowsLinear()) return;
	if(auto decl=cast(Declaration)e){
		if(decl.isLinear()){
			sc.error(format("cannot make linear declaration '%s' at this location",e),e.loc);
			e.sstate=SemState.error;
		}
	}
}


Expression[] semantic(Expression[] exprs,Scope sc){
	bool success=true;
	foreach(ref expr;exprs) if(!cast(BinaryExp!(Tok!":="))expr&&!cast(CommaExp)expr) expr=makeDeclaration(expr,success,sc); // TODO: get rid of special casing?
	/+foreach(ref expr;exprs){
	 if(auto decl=cast(Declaration)expr) expr=presemantic(decl,sc);
		if(cast(BinaryExp!(Tok!":="))expr) expr=makeDeclaration(expr,success,sc);
	}+/
	foreach(ref expr;exprs){
		if(auto decl=cast(Declaration)expr) expr=presemantic(decl,sc);
		expr=toplevelSemantic(expr,sc);
		success&=expr.sstate==SemState.completed;
	}
	if(!sc.allowsLinear()){
		foreach(ref expr;exprs){
			checkNotLinear(expr,sc);
		}
	}
	return exprs;
}

Expression toplevelSemantic(Expression expr,Scope sc){
	if(expr.sstate==SemState.error) return expr;
	if(auto fd=cast(FunctionDef)expr) return functionDefSemantic(fd,sc);
	if(auto dd=cast(DatDecl)expr) return datDeclSemantic(dd,sc);
	if(cast(BinaryExp!(Tok!":="))expr||cast(DefExp)expr) return colonOrAssignSemantic(expr,sc);
	if(auto ce=cast(CommaExp)expr) return expectColonOrAssignSemantic(ce,sc);
	if(auto imp=cast(ImportExp)expr){
		assert(util.among(imp.sstate,SemState.error,SemState.completed));
		return imp;
	}
	sc.error("not supported at toplevel",expr.loc);
	expr.sstate=SemState.error;
	return expr;
}

bool isBuiltIn(Identifier id){
	if(!id||id.meaning) return false;
	switch(id.name){
	case "π":
	case "readCSV":
	case /+"Marginal","sampleFrom",+/"quantumPrimitive","__show","__query":
	/+case "Expectation":
		return true;+/
	case "*","𝟙","𝟚","B","𝔹","N","ℕ","Z","ℤ","Q","ℚ","R","ℝ","C","ℂ":
		return true;
	default: return false;
	}
}

Expression distributionTy(Expression base,Scope sc){
	return typeSemantic(new CallExp(varTy("Distribution",funTy(typeTy,typeTy,true,false,true)),base,true,true),sc);
}

Expression builtIn(Identifier id,Scope sc){
	Expression t=null;
	switch(id.name){
	case "readCSV": t=funTy(stringTy(true),arrayTy(ℝ(true)),false,false,true); break;
	case "π": t=ℝ(true); break;
	case "Marginal","sampleFrom","quantumPrimitive","__query","__show": t=unit; break; // those are actually magic polymorphic functions
	case "Expectation": t=funTy(ℝ(false),ℝ(false),false,false,true); break; // TODO: should be lifted
	case "*","𝟙","𝟚","B","𝔹","N","ℕ","Z","ℤ","Q","ℚ","R","ℝ","C","ℂ":
		id.type=typeTy;
		if(id.name=="*") return typeTy;
		if(id.name=="𝟙") return unit;
		if(id.name=="𝟚"||id.name=="B"||id.name=="𝔹") return Bool(false);
		if(id.name=="N"||id.name=="ℕ") return ℕt(false);
		if(id.name=="Z"||id.name=="ℤ") return ℤt(false);
		if(id.name=="Q"||id.name=="ℚ") return ℚt(false);
		if(id.name=="R"||id.name=="ℝ") return ℝ(false);
		if(id.name=="C"||id.name=="ℂ") return ℂ(false);
	default: return null;
	}
	id.type=t;
	id.sstate=SemState.completed;
	return id;
}

bool isBuiltIn(FieldExp fe)in{
	assert(fe.e.sstate==SemState.completed);
}body{
	if(fe.f.meaning) return false;
	if(auto at=cast(ArrayTy)fe.e.type){
		if(fe.f.name=="length"){
			return true;
		}
	}
	return false;
}

Expression builtIn(FieldExp fe,Scope sc)in{
	assert(fe.e.sstate==SemState.completed);
}body{
	if(fe.f.meaning) return null;
	if(auto at=cast(ArrayTy)fe.e.type){
		if(fe.f.name=="length"){
			fe.type=ℕt(true); // no superpositions over arrays with different lengths
			fe.f.sstate=SemState.completed;
			return fe;
		}else return null;
	}
	return null;
}

bool isFieldDecl(Expression e){
	if(cast(VarDecl)e) return true;
	if(auto tae=cast(TypeAnnotationExp)e)
		if(auto id=cast(Identifier)tae.e)
			return true;
	return false;
}

Expression fieldDeclSemantic(Expression e,Scope sc)in{
	assert(isFieldDecl(e));
}body{
	e.sstate=SemState.completed;
	return e;
}

Expression expectFieldDeclSemantic(Expression e,Scope sc){
	if(auto ce=cast(CommaExp)e){
		ce.e1=expectFieldDeclSemantic(ce.e1,sc);
		ce.e2=expectFieldDeclSemantic(ce.e2,sc);
		propErr(ce.e1,ce);
		propErr(ce.e2,ce);
		return ce;
	}
	if(isFieldDecl(e)) return fieldDeclSemantic(e,sc);
	sc.error("expected field declaration",e.loc);
	e.sstate=SemState.error;
	return e;
}

Expression nestedDeclSemantic(Expression e,Scope sc){
	if(auto fd=cast(FunctionDef)e)
		return functionDefSemantic(fd,sc);
	if(auto dd=cast(DatDecl)e)
		return datDeclSemantic(dd,sc);
	if(isFieldDecl(e)) return fieldDeclSemantic(e,sc);
	if(auto ce=cast(CommaExp)e) return expectFieldDeclSemantic(ce,sc);
	sc.error("not a declaration",e.loc);
	e.sstate=SemState.error;
	return e;
}

CompoundDecl compoundDeclSemantic(CompoundDecl cd,Scope sc){
	auto asc=cd.ascope_;
	if(!asc) asc=new AggregateScope(sc);
	++asc.getDatDecl().semanticDepth;
	scope(exit) if(--asc.getDatDecl().semanticDepth==0&&!asc.close()) cd.sstate=SemState.error;
	cd.ascope_=asc;
	bool success=true; // dummy
	foreach(ref e;cd.s) e=makeDeclaration(e,success,asc);
	foreach(ref e;cd.s) if(auto decl=cast(Declaration)e) e=presemantic(decl,asc);
	foreach(ref e;cd.s){
		e=nestedDeclSemantic(e,asc);
		propErr(e,cd);
	}
	if(!sc.allowsLinear()){
		foreach(ref e;cd.s){
			checkNotLinear(e,sc);
			propErr(e,cd);
		}
	}
	cd.type=unit;
	return cd;
}

Expression statementSemantic(Expression e,Scope sc){
	assert(sc.allowsLinear());
	scope(exit){
		sc.pushConsumed();
		sc.resetConst();
	}
	if(auto ce=cast(CallExp)e)
		return callSemantic(ce,sc,ConstResult.yes);
	if(auto ite=cast(IteExp)e){
		ite.cond=expressionSemantic(ite.cond,sc,ConstResult.yes);
		sc.pushConsumed();
		if(ite.cond.sstate==SemState.completed && !cast(BoolTy)ite.cond.type){
			sc.error(format("type of condition should be !𝔹 or 𝔹, not %s",ite.cond.type),ite.cond.loc);
			ite.sstate=SemState.error;
		}
		auto quantumControl=ite.cond.type!=Bool(true);
		auto restriction_=quantumControl?Annotation.mfree:Annotation.none;
		ite.then=controlledCompoundExpSemantic(ite.then,sc,ite.cond,restriction_);
		if(ite.othw) ite.othw=controlledCompoundExpSemantic(ite.othw,sc,ite.cond,restriction_);
		propErr(ite.cond,ite);
		propErr(ite.then,ite);
		if(ite.othw) propErr(ite.othw,ite);
		if(sc.merge(quantumControl,ite.then.blscope_,ite.othw?cast(Scope)ite.othw.blscope_:new BlockScope(sc,restriction_)))
			ite.sstate=SemState.error;
		ite.type=unit;
		return ite;
	}
	if(auto ret=cast(ReturnExp)e)
		return returnExpSemantic(ret,sc);
	if(auto fd=cast(FunctionDef)e)
		return functionDefSemantic(fd,sc);
	if(auto dd=cast(DatDecl)e)
		return datDeclSemantic(dd,sc);
	if(auto ce=cast(CommaExp)e) return expectColonOrAssignSemantic(ce,sc);
	if(isColonOrAssign(e)) return colonOrAssignSemantic(e,sc);
	if(auto fe=cast(ForExp)e){
		assert(!fe.bdy.blscope_);
		fe.left=expressionSemantic(fe.left,sc,ConstResult.no);
		sc.pushConsumed();
		if(fe.left.sstate==SemState.completed && !isSubtype(fe.left.type, ℝ(true))){
			sc.error(format("lower bound for loop variable should be a classical number, not %s",fe.left.type),fe.left.loc);
			fe.sstate=SemState.error;
		}
		fe.right=expressionSemantic(fe.right,sc,ConstResult.no);
		sc.pushConsumed();
		if(fe.right.sstate==SemState.completed && !isSubtype(fe.right.type, ℝ(true))){
			sc.error(format("upper bound for loop variable should be a classical number, not %s",fe.right.type),fe.right.loc);
			fe.sstate=SemState.error;
		}
		auto fesc=fe.bdy.blscope_=new BlockScope(sc);
		auto vd=new VarDecl(fe.var);
		vd.vtype=fe.left.type && fe.right.type ? joinTypes(fe.left.type, fe.right.type) : ℤt(true);
		assert(fe.sstate==SemState.error||vd.vtype.isClassical());
		if(fe.sstate==SemState.error){
			vd.vtype=vd.vtype.getClassical();
			if(!vd.vtype) vd.vtype=ℤt(true);
		}
		vd.loc=fe.var.loc;
		if(vd.name.name!="_"&&!fesc.insert(vd))
			fe.sstate=SemState.error;
		fe.var.name=vd.getName;
		fe.fescope_=fesc;
		fe.loopVar=vd;
		fe.bdy=compoundExpSemantic(fe.bdy,sc);
		assert(!!fe.bdy);
		propErr(fe.left,fe);
		propErr(fe.right,fe);
		propErr(fe.bdy,fe);
		if(sc.merge(false,fesc,new BlockScope(sc))){
			sc.note("possibly consumed in for loop", fe.loc);
			fe.sstate=SemState.error;
		}
		fe.type=unit;
		return fe;
	}
	if(auto we=cast(WhileExp)e){
		we.cond=expressionSemantic(we.cond,sc,ConstResult.no);
		sc.pushConsumed();
		if(we.cond.sstate==SemState.completed && we.cond.type!=Bool(true)){
			sc.error(format("type of condition should be !𝔹, not %s",we.cond.type),we.cond.loc);
			we.sstate=SemState.error;
		}
		we.bdy=compoundExpSemantic(we.bdy,sc);
		propErr(we.cond,we);
		propErr(we.bdy,we);
		if(we.cond.sstate==SemState.completed){
			import parser: parseExpression;
			auto ncode='\n'.repeat(we.cond.loc.line?we.cond.loc.line-1:0).to!string~we.cond.loc.rep~"\0\0\0\0";
			auto nsource=new Source(we.cond.loc.source.name,ncode);
			auto condDup=parseExpression(nsource,sc.handler); // TODO: this is an ugly hack, implement dup
			assert(!!condDup);
			condDup.loc=we.cond.loc;
			condDup=expressionSemantic(condDup,we.bdy.blscope_,ConstResult.no);
			we.bdy.blscope_.pushConsumed();
			if(condDup.sstate==SemState.error)
				sc.note("possibly consumed in while loop", we.loc);
			propErr(condDup,we);
		}
		if(sc.merge(false,we.bdy.blscope_,new BlockScope(sc))){
			sc.note("possibly consumed in while loop", we.loc);
			we.sstate=SemState.error;
		}
		we.type=unit;
		return we;
	}
	if(auto re=cast(RepeatExp)e){
		re.num=expressionSemantic(re.num,sc,ConstResult.no);
		sc.pushConsumed();
		if(re.num.sstate==SemState.completed && !isSubtype(re.num.type, ℤt(true))){
			sc.error(format("number of iterations should be a classical integer, not %s",re.num.type),re.num.loc);
			re.sstate=SemState.error;
		}
		re.bdy=compoundExpSemantic(re.bdy,sc);
		propErr(re.num,re);
		propErr(re.bdy,re);
		if(sc.merge(false,re.bdy.blscope_,new BlockScope(sc))){
			sc.note("possibly consumed in repeat loop", re.loc);
			re.sstate=SemState.error;
		}
		re.type=unit;
		return re;
	}
	if(auto oe=cast(ObserveExp)e){
		oe.e=expressionSemantic(oe.e,sc,ConstResult.no);
		if(oe.e.sstate==SemState.completed && oe.e.type!is Bool(true)){
			sc.error(format("type of condition should be !𝔹, not %s",oe.e.type),oe.e.loc);
			oe.sstate=SemState.error;
		}
		propErr(oe.e,oe);
		oe.type=unit;
		return oe;
	}
	if(auto oe=cast(CObserveExp)e){ // TODO: get rid of cobserve!
		oe.var=expressionSemantic(oe.var,sc,ConstResult.no);
		oe.val=expressionSemantic(oe.val,sc,ConstResult.no);
		propErr(oe.var,oe);
		propErr(oe.val,oe);
		if(oe.sstate==SemState.error)
			return oe;
		if(oe.var.type!is ℝ(true) || oe.val.type !is ℝ(true)){
			sc.error("both arguments to cobserve should be classical real numbers",oe.loc);
			oe.sstate=SemState.error;
		}
		oe.type=unit;
		return oe;
	}
	if(auto ae=cast(AssertExp)e){
		ae.e=expressionSemantic(ae.e,sc,ConstResult.no);
		if(ae.e.sstate==SemState.completed && ae.e.type!is Bool(true)){
			sc.error(format("type of condition should be !𝔹, not %s",ae.e.type),ae.e.loc);
			ae.sstate=SemState.error;
		}
		propErr(ae.e,ae);
		ae.type=unit;
		return ae;
	}
	if(auto fe=cast(ForgetExp)e){
		bool canForgetImplicitly;
		bool checkImplicitForget(Expression var){
			auto id=cast(Identifier)var;
			if(!id) return false;
			auto meaning=sc.lookup(id,false,true,Lookup.probing);
			return meaning&&sc.canForget(meaning);
		}
		if(auto tpl=cast(TupleExp)fe.var) canForgetImplicitly=tpl.e.all!checkImplicitForget;
		else canForgetImplicitly=checkImplicitForget(fe.var);
		auto var=expressionSemantic(fe.var,sc,ConstResult.no);
		propErr(var,fe);
		if(!cast(Identifier)fe.var){
			auto tpl=cast(TupleExp)fe.var;
			if(!tpl||!tpl.e.all!(x=>!!cast(Identifier)x)){
				sc.error("left-hand side of 'forget' must be identifier or tuple of identifiers",fe.var.loc);
				fe.sstate=fe.var.sstate=SemState.error;
			}
		}
		if(fe.val){
			fe.val=expressionSemantic(fe.val,sc,ConstResult.yes);
			propErr(fe.val,fe);
			if(fe.sstate!=SemState.error&&!fe.val.isLifted()){
				sc.error("forget expression must be 'lifted'",fe.val.loc);
				fe.sstate=SemState.error;
			}
			if(fe.var.type&&fe.val.type && !joinTypes(fe.var.type,fe.val.type)){
				sc.error(format("incompatible types '%s' and '%s' for forget",fe.var.type,fe.val.type),fe.loc);
				fe.sstate=SemState.error;
			}
		}else if(!canForgetImplicitly){
			sc.error(format("cannot synthesize forget expression for '%s'",var),fe.loc);
		}
		return fe;
	}
	sc.error("not supported at this location",e.loc);
	e.sstate=SemState.error;
	return e;
}

CompoundExp controlledCompoundExpSemantic(CompoundExp ce,Scope sc,Expression control,Annotation restriction_)in{
	assert(!ce.blscope_);
}do{
	if(control.isLifted()){
		ce.blscope_=new BlockScope(sc,restriction_);
		ce.blscope_.addControlDependency(control.getDependency(ce.blscope_));
	}
	return compoundExpSemantic(ce,sc,restriction_);
}

CompoundExp compoundExpSemantic(CompoundExp ce,Scope sc,Annotation restriction_=Annotation.none){
	if(!ce.blscope_) ce.blscope_=new BlockScope(sc,restriction_);
	foreach(ref e;ce.s){
		//writeln("before: ",e," ",sc.symtab);
		e=statementSemantic(e,ce.blscope_);
		//writeln("after: ",e," ",sc.symtab);
		propErr(e,ce);
	}
	ce.type=unit;
	return ce;
}

VarDecl varDeclSemantic(VarDecl vd,Scope sc){
	bool success=true;
	if(!vd.scope_) makeDeclaration(vd,success,sc);
	vd.type=unit;
	if(!success) vd.sstate=SemState.error;
	if(!vd.vtype){
		assert(vd.dtype,text(vd));
		vd.vtype=typeSemantic(vd.dtype,sc);
	}
	if(auto prm=cast(Parameter)vd){
		if(sc.restriction>=Annotation.lifted)
			prm.isConst=true;
		if(vd.vtype&&vd.vtype.impliesConst())
			prm.isConst=true;
	}
	if(!vd.vtype) vd.sstate=SemState.error;
	if(vd.sstate!=SemState.error)
		vd.sstate=SemState.completed;
	return vd;
}

Dependency getDependency(Expression e,Scope sc)in{
	assert(e.isLifted());
}do{
	SetX!string names;
	foreach(id;e.freeIdentifiers){
		if(id.type&&!id.type.isClassical){
			if(!sc.dependencyTracked(id)) // for variables captured in closure
				return Dependency(true);
			names.insert(id.name);
		}
	}
	return Dependency(false, names);
}

Expression colonAssignSemantic(BinaryExp!(Tok!":=") be,Scope sc){
	if(cast(IndexExp)be.e1) return indexReplaceSemantic(be,sc);
	if(auto tpl=cast(TupleExp)be.e1) if(tpl.e.any!(x=>!!cast(IndexExp)x)) return permuteSemantic(be,sc);
	bool success=true;
	auto e2orig=be.e2;
	be.e2=expressionSemantic(be.e2,sc,ConstResult.no);
	auto de=cast(DefExp)makeDeclaration(be,success,sc);
	if(!de) be.sstate=SemState.error;
	assert(success && de && de.initializer is be || !de||de.sstate==SemState.error);
	if(be.e2.sstate==SemState.completed){
		if(auto tpl=cast(TupleExp)be.e1){
			if(auto tt=be.e2.type.isTupleTy){
				if(tpl.length!=tt.length){
					sc.error(text("inconsistent number of tuple entries for definition: ",tpl.length," vs. ",tt.length),de.loc);
					if(de){ de.setError(); be.sstate=SemState.error; }
				}
			}else{
				sc.error(format("cannot unpack type %s as a tuple",be.e2.type),de.loc);
				if(de){ de.setError(); be.sstate=SemState.error; }
			}
		}
		if(de){
			if(de.sstate!=SemState.error){
				de.setType(be.e2.type);
				de.setInitializer();
				foreach(vd;de.decls){
					auto nvd=varDeclSemantic(vd,sc);
					assert(nvd is vd);
				}
			}
			de.type=unit;
			if(de.sstate!=SemState.error&&sc.getFunction()){
				foreach(vd;de.decls){
					if(vd.initializer){
						if(vd.initializer.isLifted())
							sc.addDependency(vd, vd.initializer.getDependency(sc));
					}else if(be.e2){
						if(be.e2.isLifted())
							sc.addDependency(vd, be.e2.getDependency(sc));
					}
				}
			}
		}
		if(cast(TopScope)sc){
			if(!be.e2.isConstant() && !cast(PlaceholderExp)be.e2 && be.e2.type!=typeTy){
				sc.error("global constant initializer must be a constant",e2orig.loc);
				if(de){ de.setError(); be.sstate=SemState.error; }
			}
		}
	}else if(de) de.setError();
	auto r=de?de:be;
	if(be.e2.type && be.e2.type.sstate==SemState.completed){
		if(auto fd=sc.getFunction()){
			auto fsc=fd.fscope_;
			assert(!!fsc);
			foreach(id;be.e2.type.freeIdentifiers){
				assert(!!id.meaning);
				auto allowMerge=fsc.allowMerge;
				fsc.allowMerge=false;
				auto meaning=fsc.lookup(id,false,true,Lookup.probing);
				fsc.allowMerge=allowMerge;
				assert(!meaning||!meaning.isLinear);
				if(meaning !is id.meaning){
					fsc.error(format("cannot use local variable '%s' in type of local variable", id.name), be.loc);
					fd.sstate=SemState.error;
				}
			}
		}
	}
	if(r.sstate!=SemState.error) r.sstate=SemState.completed;
	return r;
}

Identifier getIdFromIndex(IndexExp e){
	if(auto idx=cast(IndexExp)e.e) return getIdFromIndex(idx);
	return cast(Identifier)e.e;
}

Expression indexReplaceSemantic(BinaryExp!(Tok!":=") be,Scope sc)in{
	assert(cast(IndexExp)be.e1);
}do{
	auto theIndex=cast(IndexExp)be.e1;
	void consumeArray(IndexExp e){
		if(auto idx=cast(IndexExp)e.e) return consumeArray(idx);
		e.e=expressionSemantic(e.e,sc,ConstResult.no); // consume array
	}
	consumeArray(theIndex);
	if(theIndex.e.type&&theIndex.e.type.isClassical()){
		sc.error(format("use assignment statement '%s = %s' to assign to classical array component",be.e1,be.e2),be.loc);
		be.sstate=SemState.error;
		theIndex=null;
		return be;
	}
	be.e1=expressionSemantic(theIndex,sc,ConstResult.yes);
	propErr(be.e1,be);
	Identifier id;
	bool check(IndexExp e){
		if(e&&(!e.a[0].isLifted()||e.a[0].type&&!e.a[0].type.isClassical())){
			sc.error("index for component replacement must be 'lifted' and classical",e.a[0].loc);
			return false;
		}
		if(e) if(auto idx=cast(IndexExp)e.e) return check(idx);
		id=e?cast(Identifier)e.e:null;
		if(e&&!checkAssignable(id?id.meaning:null,theIndex.e.loc,sc,true))
			return false;
		return true;
	}
	if(be.sstate==SemState.error) theIndex=null;
	else if(!check(theIndex)){
		be.sstate=SemState.error;
		theIndex=null;
	}
	assert(!sc.indexToReplace);
	sc.indexToReplace=theIndex;
	be.e2=expressionSemantic(be.e2,sc,ConstResult.no);
	propErr(be.e2,be);
	if(sc.indexToReplace){
		sc.error("reassigned component must be consumed in right-hand side", be.e1.loc);
		be.sstate=SemState.error;
		sc.indexToReplace=null;
	}
	if(id) addVar(id.name,id.type,be.loc,sc);
	be.type=unit;
	if(be.sstate!=SemState.error) be.sstate=SemState.completed;
	return be;
}

Expression permuteSemantic(BinaryExp!(Tok!":=") be,Scope sc)in{
	auto tpl=cast(TupleExp)be.e1;
	assert(tpl&&tpl.e.any!(x=>!!cast(IndexExp)x));
}do{
	be.e1=expressionSemantic(be.e1,sc,ConstResult.yes);
	propErr(be.e1,be);
	be.e2=expressionSemantic(be.e2,sc,ConstResult.yes);
	propErr(be.e2,be);
	if(be.e1.type&&be.e1.type.isClassical()){
		sc.error(format("use assignment statement '%s = %s' to assign to classical array components",be.e1,be.e2),be.loc);
		be.sstate=SemState.error;
		return be;
	}
	auto tpl1=cast(TupleExp)be.e1, tpl2=cast(TupleExp)be.e2;
	if(!tpl1||!tpl2||tpl1.e.length!=2||tpl2.e.length!=2||tpl1.e[0]!=tpl2.e[1]||tpl1.e[1]!=tpl2.e[0]){
		sc.error("only swapping supported in permute statement", be.loc);
		be.sstate=SemState.error;
		return be;
	}
	if(!chain(tpl1.e,tpl2.e).all!(x=>!!cast(IndexExp)x||!!cast(Identifier)x)){
		sc.error("only swapping of variables and array components supported in permute statement", be.loc);
		be.sstate=SemState.error;
		return be;
	}
	foreach(e;chain(tpl1.e,tpl2.e)){
		if(auto idx=cast(IndexExp)e){
			bool check(IndexExp e){
				if(e&&(!e.a[0].isLifted()||e.a[0].type&&!e.a[0].type.isClassical())){
					sc.error("index in permute statement must be 'lifted' and classical",e.a[0].loc);
					return false;
				}
				if(e) if(auto idx=cast(IndexExp)e.e) return check(idx);
				auto id=e?cast(Identifier)e.e:null;
				if(e&&!checkAssignable(id?id.meaning:null,id.loc,sc,true))
					return false;
				return true;
			}
			if(!check(idx)){
				be.sstate=SemState.error;
				return be;
			}
		}else if(auto id=cast(Identifier)e){
			if(!checkAssignable(id.meaning,id.loc,sc,true)){
				be.sstate=SemState.error;
				return be;
			}
		}
	}
	be.sstate=SemState.completed; // TODO: redefine variables in local scope?
	return be;
}

bool checkAssignable(Declaration meaning,Location loc,Scope sc,bool quantumAssign=false){
	if(!cast(VarDecl)meaning){
		sc.error("can only assign to variables",loc);
		return false;
	}else if(cast(Parameter)meaning&&(cast(Parameter)meaning).isConst){
		sc.error("cannot reassign 'const' parameters",loc);
		return false;
	}else{
		auto vd=cast(VarDecl)meaning;
		if(!quantumAssign&&!vd.vtype.isClassical()&&!sc.canForget(meaning)){
			sc.error("cannot reassign quantum variable", loc);
			return false;
		}else if(vd.vtype==typeTy){
			sc.error("cannot reassign type variables", loc);
			return false;
		}
		for(auto csc=sc;csc !is meaning.scope_;csc=(cast(NestedScope)csc).parent){
			if(auto fsc=cast(FunctionScope)csc){
				// TODO: what needs to be done to lift this restriction?
				// TODO: method calls are also implicit assignments.
				sc.error("cannot assign to variable in closure context (capturing by value)",loc);
				return false;
			}
		}
	}
	return true;
}

AssignExp assignExpSemantic(AssignExp ae,Scope sc){
	ae.type=unit;
	ae.e1=expressionSemantic(ae.e1,sc,ConstResult.yes); // reassigned variable should not be consumed (otherwise, can use ':=')
	propErr(ae.e1,ae);
	if(ae.sstate==SemState.error)
		return ae;
	void checkLhs(Expression lhs){
		if(auto id=cast(Identifier)lhs){
			if(!checkAssignable(id.meaning,ae.loc,sc))
				ae.sstate=SemState.error;
		}else if(auto tpl=cast(TupleExp)lhs){
			foreach(exp;tpl.e)
				checkLhs(exp);
		}else if(auto idx=cast(IndexExp)lhs){
			checkLhs(idx.e);
		}else if(auto fe=cast(FieldExp)lhs){
			checkLhs(fe.e);
		}else if(auto tae=cast(TypeAnnotationExp)lhs){
			checkLhs(tae.e);
		}else{
		LbadAssgnmLhs:
			sc.error(format("cannot assign to %s",lhs),ae.e1.loc);
			ae.sstate=SemState.error;
		}
	}
	checkLhs(ae.e1);
	ae.e2=expressionSemantic(ae.e2,sc,ConstResult.no);
	propErr(ae.e2,ae);
	if(ae.sstate!=SemState.error&&!isSubtype(ae.e2.type,ae.e1.type)){
		if(auto id=cast(Identifier)ae.e1){
			sc.error(format("cannot assign %s to variable %s of type %s",ae.e2.type,id,id.type),ae.loc);
			assert(!!id.meaning);
			sc.note("declared here",id.meaning.loc);
		}else sc.error(format("cannot assign %s to %s",ae.e2.type,ae.e1.type),ae.loc);
		ae.sstate=SemState.error;
	}
	enum Stage{
		collectDeps,
		consumeLhs,
		defineVars
	}
	Dependency[] dependencies;
	int curDependency;
	void updateDependencies(Expression lhs,Expression rhs,bool expandTuples,Stage stage){
		if(auto id=cast(Identifier)lhs){
			if(id&&id.meaning&&id.meaning.name){
				final switch(stage){
					case Stage.collectDeps:
						if(rhs.isLifted()) dependencies~=rhs.getDependency(sc);
						break;
					case Stage.consumeLhs:
						sc.consume(id.meaning);
						break;
					case Stage.defineVars:
						auto name=id.meaning.name.name;
						auto var=addVar(name,id.type,lhs.loc,sc);
						if(rhs.isLifted()) sc.addDependency(var,dependencies[curDependency++]);
						break;
				}
			}
		}else if(auto tpll=cast(TupleExp)lhs){
			bool ok=false;
			if(expandTuples){
				if(auto tplr=cast(TupleExp)rhs){
					if(tpll.e.length==tplr.e.length){
						foreach(i;0..tpll.e.length)
							updateDependencies(tpll.e[i],tplr.e[i],true,stage);
						ok=true;
					}
				}
			}
			if(!ok) foreach(exp;tpll.e) updateDependencies(exp,rhs,false,stage);
		}else if(auto idx=cast(IndexExp)lhs){
			updateDependencies(idx.e,rhs,false,stage);
		}else if(auto fe=cast(FieldExp)lhs){
			updateDependencies(fe.e,rhs,false,stage);
		}else if(auto tae=cast(TypeAnnotationExp)lhs){
			updateDependencies(tae.e,rhs,expandTuples,stage);
		}else assert(0);
	}
	if(ae.sstate!=SemState.error){
		updateDependencies(ae.e1,ae.e2,true,Stage.collectDeps);
		updateDependencies(ae.e1,ae.e2,true,Stage.consumeLhs);
		foreach(ref dependency;dependencies)
			foreach(name;sc.toPush)
				sc.pushUp(dependency, name);
		sc.pushConsumed();
		updateDependencies(ae.e1,ae.e2,true,Stage.defineVars);
	}
	if(ae.sstate!=SemState.error) ae.sstate=SemState.completed;
	return ae;
}

bool isOpAssignExp(Expression e){
	return cast(OrAssignExp)e||cast(AndAssignExp)e||cast(AddAssignExp)e||cast(SubAssignExp)e||cast(MulAssignExp)e||cast(DivAssignExp)e||cast(IDivAssignExp)e||cast(ModAssignExp)e||cast(PowAssignExp)e||cast(CatAssignExp)e||cast(BitOrAssignExp)e||cast(BitXorAssignExp)e||cast(BitAndAssignExp)e;
}

bool isInvertibleOpAssignExp(Expression e){
	return cast(AddAssignExp)e||cast(SubAssignExp)e||cast(CatAssignExp)e||cast(BitXorAssignExp)e;
}

ABinaryExp opAssignExpSemantic(ABinaryExp be,Scope sc)in{
	assert(isOpAssignExp(be));
}body{
	if(auto id=cast(Identifier)be.e1){
		int nerr=sc.handler.nerrors; // TODO: this is a bit hacky
		auto meaning=sc.lookup(id,false,true,Lookup.probing);
		if(nerr!=sc.handler.nerrors){
			sc.note("looked up here",id.loc);
			return be;
		}
		if(meaning){
			id.meaning=meaning;
			id.name=meaning.getName;
			id.type=typeForDecl(meaning);
			id.scope_=sc;
			id.sstate=SemState.completed;
		}else{
			sc.error(format("undefined identifier %s",id.name),id.loc);
			id.sstate=SemState.error;
		}
	}else be.e1=expressionSemantic(be.e1,sc,ConstResult.no);
	be.e2=expressionSemantic(be.e2,sc,cast(CatAssignExp)be?ConstResult.no:ConstResult.yes);
	propErr(be.e1,be);
	propErr(be.e2,be);
	if(be.sstate==SemState.error)
		return be;
	void checkULhs(Expression lhs){
		if(auto id=cast(Identifier)lhs){
			if(!checkAssignable(id.meaning,be.loc,sc,isInvertibleOpAssignExp(be)))
			   be.sstate=SemState.error;
		}else if(auto idx=cast(IndexExp)lhs){
			checkULhs(idx.e);
		}else if(auto fe=cast(FieldExp)lhs){
			checkULhs(fe.e);
		}else{
		LbadAssgnmLhs:
			sc.error(format("cannot update-assign to %s",lhs),be.e1.loc);
			be.sstate=SemState.error;
		}
	}
	Expression ce=null;
	import parser;
	static foreach(op;binaryOps){
		static if(op.endsWith("←")){
			if(auto ae=cast(BinaryExp!(Tok!op))be){
				ce=new BinaryExp!(Tok!(op[0..$-"←".length]))(be.e1, be.e2);
				ce.loc=be.loc;
			}
		}
	}
	assert(!!ce);
	ce=expressionSemantic(ce,sc,ConstResult.no);
	propErr(ce, be);
	checkULhs(be.e1);
	if(be.sstate!=SemState.error&&!isSubtype(ce.type, be.e1.type)){
		sc.error(format("incompatible operand types %s and %s",be.e1.type,be.e2.type),be.loc);
		be.sstate=SemState.error;
	}
	auto id=cast(Identifier)be.e1;
	if(be.sstate!=SemState.error&&!be.e1.type.isClassical()){
		if(!id){
			sc.error(format("cannot update-assign to quantum expression %s",be.e1),be.e1.loc);
			be.sstate=SemState.error;
		}else if((!isInvertibleOpAssignExp(be)||be.e2.hasFreeIdentifier(id.name))&&id.meaning&&!sc.canForget(id.meaning)){
			sc.error("quantum update must be invertible",be.loc);
			be.sstate=SemState.error;
		}
		if(id&&id.meaning&&id.meaning.name){
			if(be.e2.isLifted()){
				auto dependency=sc.getDependency(id.meaning);
				dependency.joinWith(be.e2.getDependency(sc));
				sc.consume(id.meaning);
				sc.pushConsumed();
				auto name=id.meaning.name.name;
				auto var=addVar(name,id.type,be.loc,sc);
				dependency.remove(name);
				sc.addDependency(var,dependency);
			}else{
				sc.consume(id.meaning);
				sc.pushConsumed();
				auto var=addVar(id.meaning.name.name,id.type,be.loc,sc);
			}
		}
	}
	be.type=unit;
	if(be.sstate!=SemState.error) be.sstate=SemState.completed;
	return be;
}

bool isAssignment(Expression e){
	return cast(AssignExp)e||isOpAssignExp(e);
}

Expression assignSemantic(Expression e,Scope sc)in{
	assert(isAssignment(e));
}body{
	if(auto ae=cast(AssignExp)e) return assignExpSemantic(ae,sc);
	if(isOpAssignExp(e)) return opAssignExpSemantic(cast(ABinaryExp)e,sc);
	assert(0);
}

bool isColonOrAssign(Expression e){
	return isAssignment(e)||cast(BinaryExp!(Tok!":="))e||cast(DefExp)e;
}

Expression colonOrAssignSemantic(Expression e,Scope sc)in{
	assert(isColonOrAssign(e));
}body{
	if(isAssignment(e)) return assignSemantic(e,sc);
	if(auto be=cast(BinaryExp!(Tok!":="))e) return colonAssignSemantic(be,sc);
	if(cast(DefExp)e) return e; // TODO: ok?
	assert(0);
}

Expression expectColonOrAssignSemantic(Expression e,Scope sc){
	if(auto ce=cast(CommaExp)e){
		ce.e1=expectColonOrAssignSemantic(ce.e1,sc);
		propErr(ce.e1,ce);
		ce.e2=expectColonOrAssignSemantic(ce.e2,sc);
		propErr(ce.e2,ce);
		ce.type=unit;
		if(ce.sstate!=SemState.error) ce.sstate=SemState.completed;
		return ce;
	}
	if(isColonOrAssign(e)) return colonOrAssignSemantic(e,sc);
	sc.error("expected assignment or variable declaration",e.loc);
	e.sstate=SemState.error;
	return e;
}

bool isReverse(Expression e){
	import parser: preludePath;
	import semantic_: modules;
	if(preludePath() !in modules) return false;
	auto exprssc=modules[preludePath()];
	auto sc=exprssc[1];
	auto id=cast(Identifier)e;
	if(!id||!id.meaning||id.meaning.scope_ !is sc) return false;
	return id.name=="reverse";
}


Expression callSemantic(CallExp ce,Scope sc,ConstResult constResult){
	if(auto id=cast(Identifier)ce.e) id.calledDirectly=true;
	ce.e=expressionSemantic(ce.e,sc,ConstResult.no);
	propErr(ce.e,ce);
	if(ce.sstate==SemState.error)
		return ce;
	scope(success){
		if(ce&&ce.sstate!=SemState.error){
			if(auto ft=cast(FunTy)ce.e.type){
				if(ft.annotation<sc.restriction()){
					if(ft.annotation==Annotation.none){
						sc.error(format("cannot call function '%s' in '%s' context", ce.e, sc.restriction()), ce.loc);
					}else{
						sc.error(format("cannot call '%s' function '%s' in '%s' context", ft.annotation, ce.e, sc.restriction()), ce.loc);
					}
					ce.sstate=SemState.error;
				}else if(constResult&&!ce.isLifted()&&!ce.type.isClassical()){
					sc.error("non-'lifted' quantum expression must be consumed", ce.loc);
					ce.sstate=SemState.error;
				}
				if(ce.arg.type.isClassical()&&ft.annotation>=Annotation.lifted){
					if(auto classical=ce.type.getClassical())
						ce.type=classical;
				}
			}
		}
	}
	auto fun=ce.e;
	bool matchArg(FunTy ft){
		if(ft.isTuple&&ft.annotation!=Annotation.lifted){
			if(auto tpl=cast(TupleExp)ce.arg){
				foreach(i,ref exp;tpl.e){
					exp=expressionSemantic(exp,sc,(ft.isConst.length==tpl.e.length?ft.isConst[i]:true)?ConstResult.yes:ConstResult.no);
					propErr(exp,tpl);
				}
				if(tpl.sstate!=SemState.error){
					tpl.type=tupleTy(tpl.e.map!(e=>e.type).array);
				}
			}else{
				ce.arg=expressionSemantic(ce.arg,sc,(ft.isConst.length?ft.isConst[0]:true)?ConstResult.yes:ConstResult.no);
				if(!ft.isConst.all!(x=>x==ft.isConst[0])){
					sc.error("cannot match single tuple to function with mixed 'const' and consumed parameters",ce.loc);
					ce.sstate=SemState.error;
					return true;
				}
			}
		}else{
			ce.arg=expressionSemantic(ce.arg,sc,((ft.isConst.length?ft.isConst[0]:true)||ft.annotation==Annotation.lifted)?ConstResult.yes:ConstResult.no);
		}
		return false;
	}
	CallExp checkFunCall(FunTy ft){
		bool tryCall(){
			if(!ce.isSquare && ft.isSquare){
				auto nft=ft;
				if(auto id=cast(Identifier)fun){
					if(auto decl=cast(DatDecl)id.meaning){
						if(auto constructor=cast(FunctionDef)decl.body_.ascope_.lookup(decl.name,false,false,Lookup.consuming)){
							if(auto cty=cast(FunTy)typeForDecl(constructor)){
								assert(ft.cod is typeTy);
								nft=productTy(ft.isConst,ft.names,ft.dom,cty,ft.isSquare,ft.isTuple,ft.annotation,true);
							}
						}
					}
				}
				if(auto codft=cast(ProductTy)nft.cod){
					if(matchArg(codft)) return true;
					propErr(ce.arg,ce);
					if(ce.arg.sstate==SemState.error) return true;
					Expression garg;
					auto tt=nft.tryMatch(ce.arg,garg);
					if(!tt) return false;
					auto nce=new CallExp(ce.e,garg,true,false);
					nce.loc=ce.loc;
					auto nnce=new CallExp(nce,ce.arg,false,false);
					nnce.loc=ce.loc;
					nnce=cast(CallExp)callSemantic(nnce,sc,ConstResult.no);
					ce=nnce;
					return true;
				}
			}
			if(matchArg(ft)) return true;
			propErr(ce.arg,ce);
			if(ce.arg.sstate==SemState.error) return true;
			ce.type=ft.tryApply(ce.arg,ce.isSquare);
			return !!ce.type;
		}
		if(isReverse(ce.e)){
			ce.arg=expressionSemantic(ce.arg,sc,(ft.isConst.length?ft.isConst[0]:true)?ConstResult.yes:ConstResult.no);
			if(auto ft2=cast(FunTy)ce.arg.type){
				if(!ft2.cod.hasAnyFreeVar(ft2.names) && ft2.annotation>=Annotation.mfree && !ft2.isSquare && ft2.isClassical()){
					Expression[] constArgTypes1;
					Expression[] argTypes;
					Expression[] constArgTypes2;
					Expression[] returnTypes;
					bool ok=true;
					if(!ft2.isTuple){
						assert(ft2.isConst.length==1);
						if(ft2.isConst[0]) constArgTypes1=[ft2.dom];
						else argTypes=[ft2.dom];
					}else{
						auto tpl=ft2.dom.isTupleTy;
						assert(!!tpl && tpl.length==ft2.isConst.length);
						auto numConstArgs1=ft2.isConst.until!(x=>!x).walkLength;
						auto numArgs=ft2.isConst[numConstArgs1..$].until!(x=>x).walkLength;
						auto numConstArgs2=ft2.isConst[numConstArgs1+numArgs..$].until!(x=>!x).walkLength;
						ok=numConstArgs1+numArgs+numConstArgs2==tpl.length;
						constArgTypes1=iota(numConstArgs1).map!(i=>tpl[i]).array;
						argTypes=iota(numConstArgs1,numConstArgs1+numArgs).map!(i=>tpl[i]).array;
						constArgTypes2=iota(numConstArgs1+numArgs,tpl.length).map!(i=>tpl[i]).array;
						if(argTypes.length==0){
							assert(constArgTypes2.length==0);
							swap(constArgTypes1,constArgTypes2);
						}
					}
					if(auto tpl=ft2.cod.isTupleTy){
						returnTypes=iota(tpl.length).map!(i=>tpl[i]).array;
					}else returnTypes=[ft2.cod];
					if(ok){
						auto nargTypes=constArgTypes1~returnTypes~constArgTypes2;
						auto nreturnTypes=argTypes;
						auto dom=nargTypes.length==1?nargTypes[0]:tupleTy(nargTypes);
						auto cod=nreturnTypes.length==1?nreturnTypes[0]:tupleTy(nreturnTypes);
						auto isConst=chain(true.repeat(constArgTypes1.length),false.repeat(returnTypes.length),true.repeat(constArgTypes2.length)).array;
						ce.type=funTy(isConst,dom,cod,false,isConst.length!=1,Annotation.mfree,true);
						return ce;
					}
				}
			}
		}
		if(!tryCall()){
			auto aty=ce.arg.type;
			if(ce.isSquare!=ft.isSquare)
				sc.error(text("function of type ",ft," cannot be called with arguments ",ce.isSquare?"[":"",aty,ce.isSquare?"]":""),ce.loc);
			else sc.error(format("expected argument types %s, but %s was provided",ft.dom,aty),ce.loc);
			ce.sstate=SemState.error;
		}
		return ce;
	}
	if(auto ft=cast(FunTy)fun.type){
		ce=checkFunCall(ft);
	}else if(auto at=isDataTyId(fun)){
		auto decl=at.decl;
		assert(fun.type is typeTy);
		auto constructor=cast(FunctionDef)decl.body_.ascope_.lookup(decl.name,false,false,Lookup.consuming);
		auto ty=cast(FunTy)typeForDecl(constructor);
		if(ty&&decl.hasParams){
			auto nce=cast(CallExp)fun;
			assert(!!nce);
			auto subst=decl.getSubst(nce.arg);
			ty=cast(ProductTy)ty.substitute(subst);
			assert(!!ty);
		}
		if(!constructor||!ty){
			sc.error(format("no constructor for type %s",at),ce.loc);
			ce.sstate=SemState.error;
		}else{
			ce=checkFunCall(ty);
			if(ce.sstate!=SemState.error){
				auto id=new Identifier(constructor.name.name);
				id.loc=fun.loc;
				id.scope_=sc;
				id.meaning=constructor;
				id.name=constructor.getName;
				id.scope_=sc;
				id.type=ty;
				id.sstate=SemState.completed;
				if(auto fe=cast(FieldExp)fun){
					assert(fe.e.sstate==SemState.completed);
					ce.e=new FieldExp(fe.e,id);
					ce.e.type=id.type;
					ce.e.loc=fun.loc;
					ce.e.sstate=SemState.completed;
				}else ce.e=id;
			}
		}
	}else if(isBuiltIn(cast(Identifier)ce.e)){
		auto id=cast(Identifier)ce.e;
		switch(id.name){
			/+case "Marginal":
				ce.type=distributionTy(ce.arg.type,sc);
				break;
			case "sampleFrom":
				return handleSampleFrom(ce,sc);+/
			case "quantumPrimitive":
				return handleQuantumPrimitive(ce,sc);
			case "__show":
				ce.arg=expressionSemantic(ce.arg,sc,ConstResult.yes);
				auto lit=cast(LiteralExp)ce.arg;
				if(lit&&lit.lit.type==Tok!"``") writeln(lit.lit.str);
				else writeln(ce.arg);
				ce.type=unit;
				break;
			case "__query":
				return handleQuery(ce,sc);
			default: assert(0,text("TODO: ",id.name));
		}
	}else{
		sc.error(format("cannot call expression of type %s",fun.type),ce.loc);
		ce.sstate=SemState.error;
	}
	return ce;
}

enum ConstResult:bool{
	no,
	yes,
}

Expression arithmeticType(bool preserveBool)(Expression t1, Expression t2){
	if(isInt(t1) && isSubtype(t2,ℤt(t1.isClassical()))) return t1; // TODO: automatic promotion to quantum
	if(isInt(t2) && isSubtype(t1,ℤt(t2.isClassical()))) return t2;
	if(isUint(t1) && isSubtype(t2,ℕt(t1.isClassical()))) return t1;
	if(isUint(t2) && isSubtype(t1,ℕt(t2.isClassical()))) return t2;
	if(preludeNumericTypeName(t1) != null||preludeNumericTypeName(t2) != null)
		return joinTypes(t1,t2);
	if(!isNumeric(t1)||!isNumeric(t2)) return null;
	auto r=joinTypes(t1,t2);
	static if(!preserveBool){
		if(r==Bool(true)) return ℕt(true);
		if(r==Bool(false)) return ℕt(false);
	}
	return r;
}
Expression subtractionType(Expression t1, Expression t2){
	auto r=arithmeticType!false(t1,t2);
	return r==ℕt(true)?ℤt(true):r==ℕt(false)?ℤt(false):r;
}
Expression divisionType(Expression t1, Expression t2){
	auto r=arithmeticType!false(t1,t2);
	if(isInt(r)||isUint(r)) return null; // TODO: add a special operator for float and rat?
	return util.among(r,Bool(true),ℕt(true),ℤt(true))?ℚt(true):
		util.among(r,Bool(false),ℕt(false),ℤt(false))?ℚt(false):r;
}
Expression iDivType(Expression t1, Expression t2){
	auto r=arithmeticType!false(t1,t2);
	if(isInt(r)||isUint(r)) return r;
	if(cast(ℂTy)t1||cast(ℂTy)t2) return null;
	bool classical=t1.isClassical()&&t2.isClassical();
	return (cast(BoolTy)t1||cast(ℕTy)t1)&&(cast(BoolTy)t2||cast(ℕTy)t2)?ℕt(classical):ℤt(classical);
}
Expression nSubType(Expression t1, Expression t2){
	auto r=arithmeticType!true(t1,t2);
	if(isUint(r)) return r;
	if(isSubtype(r,ℕt(false))) return r;
	if(isSubtype(r,ℤt(false))) return ℕt(r.isClassical());
	return null;
}
Expression moduloType(Expression t1, Expression t2){
	auto r=arithmeticType!false(t1,t2);
	return r==ℤt(true)?ℕt(true):r==ℤt(false)?ℕt(false):r; // TODO: more general range information?
}
Expression powerType(Expression t1, Expression t2){
	bool classical=t1.isClassical()&&t2.isClassical();
	if(!isNumeric(t1)||!isNumeric(t2)) return null;
	if(cast(BoolTy)t1&&isSubtype(t2,ℕt(classical))) return Bool(classical);
	if(cast(ℕTy)t1&&isSubtype(t2,ℕt(classical))) return ℕt(classical);
	if(cast(ℂTy)t1||cast(ℂTy)t2) return ℂ(classical);
	if(util.among(t1,Bool(true),ℕt(true),ℤt(true),ℚt(true))&&isSubtype(t2,ℤt(false))) return ℚt(t2.isClassical);
	if(util.among(t1,Bool(false),ℕt(false),ℤt(false),ℚt(false))&&isSubtype(t2,ℤt(false))) return ℚt(false);
	return ℝ(classical); // TODO: good?
}
Expression minusBitNotType(Expression t){
	if(!isNumeric(t)) return null;
	if(cast(BoolTy)t||cast(ℕTy)t) return ℤt(t.isClassical());
	return t;
}
Expression notType(Expression t){
	if(!cast(BoolTy)t) return null;
	return t;
}
Expression logicType(Expression t1,Expression t2){
	if(!cast(BoolTy)t1||!cast(BoolTy)t2) return null;
	return Bool(t1.isClassical()&&t2.isClassical());
}
Expression cmpType(Expression t1,Expression t2){
	if(preludeNumericTypeName(t1) != null||preludeNumericTypeName(t2) != null){
		if(!(joinTypes(t1,t2)||isNumeric(t1)||isNumeric(t2)))
			return null;
	}else{
		auto a1=cast(ArrayTy)t1,a2=cast(ArrayTy)t2;
		auto v1=cast(VectorTy)t1,v2=cast(VectorTy)t2;
		Expression n1=a1?a1.next:v1?v1.next:null,n2=a2?a2.next:v2?v2.next:null;
		if(n1&&n2) return cmpType(n1,n2);
		if(!isNumeric(t1)||!isNumeric(t2)||cast(ℂTy)t1||cast(ℂTy)t2) return null;
	}
	return Bool(t1.isClassical()&&t2.isClassical());
}

Expression expressionSemantic(Expression expr,Scope sc,ConstResult constResult){
	if(expr.sstate==SemState.completed||expr.sstate==SemState.error) return expr;
	if(expr.sstate==SemState.started){
		sc.error("cyclic dependency",expr.loc);
		expr.sstate=SemState.error;
		return expr;
	}
	assert(expr.sstate==SemState.initial);
	expr.sstate=SemState.started;
	scope(success){
		expr.constLookup=constResult;
		if(expr&&expr.sstate!=SemState.error){
			if(constResult&&!expr.isLifted()&&!expr.type.isClassical()){
				sc.error("non-'lifted' quantum expression must be consumed", expr.loc);
				expr.sstate=SemState.error;
			}else{
				assert(!!expr.type);
				expr.sstate=SemState.completed;
			}
		}
		if(expr.type==ℕt(false)||expr.type==ℤt(false)||expr.type==ℚt(false)||expr.type==ℝ(false)||expr.type==ℂ(false)){
			sc.error(format("instances of type '%s' not realizable",expr.type),expr.loc);
			expr.sstate=SemState.error;
		}
	}
	if(auto cd=cast(CompoundDecl)expr)
		return compoundDeclSemantic(cd,sc);
	if(auto ce=cast(CompoundExp)expr)
		return compoundExpSemantic(ce,sc);
	if(auto le=cast(LambdaExp)expr){
		FunctionDef nfd=le.fd;
		if(!le.fd.scope_){
			le.fd.scope_=sc;
			nfd=cast(FunctionDef)presemantic(nfd,sc);
		}else assert(le.fd.scope_ is sc);
		assert(!!nfd);
		le.fd=functionDefSemantic(nfd,sc);
		assert(!!le.fd);
		propErr(le.fd,le);
		if(le.fd.sstate==SemState.completed)
			le.type=typeForDecl(le.fd);
		if(le.fd.sstate==SemState.completed) le.sstate=SemState.completed;
		return le;
	}
	if(auto fd=cast(FunctionDef)expr){
		sc.error("function definition cannot appear within an expression",fd.loc);
		fd.sstate=SemState.error;
		return fd;
	}
	if(auto ret=cast(ReturnExp)expr){
		sc.error("return statement cannot appear within an expression",ret.loc);
		ret.sstate=SemState.error;
		return ret;
	}
	if(auto ce=cast(CallExp)expr)
		return expr=callSemantic(ce,sc,constResult);
	if(auto id=cast(Identifier)expr){
		id.scope_=sc;
		auto meaning=id.meaning;
		if(!meaning){
			int nerr=sc.handler.nerrors; // TODO: this is a bit hacky
			meaning=sc.lookup(id,false,true,constResult?Lookup.constant:Lookup.consuming);
			if(nerr!=sc.handler.nerrors){
				sc.note("looked up here",id.loc);
				id.sstate=SemState.error;
				return id;
			}
			if(!meaning){
				if(auto r=builtIn(id,sc)){
					if(!id.calledDirectly&&util.among(id.name,"Expectation","Marginal","sampleFrom","__query","__show")){
						sc.error("special operator must be called directly",id.loc);
						id.sstate=r.sstate=SemState.error;
					}
					return r;
				}
				sc.error(format("undefined identifier %s",id.name),id.loc);
				id.sstate=SemState.error;
				return id;
			}
			if(auto fd=cast(FunctionDef)meaning)
				if(auto asc=isInDataScope(fd.scope_))
					if(fd.name.name==asc.decl.name.name)
						meaning=asc.decl;
			id.meaning=meaning;
		}
		id.name=meaning.getName;
		propErr(meaning,id);
		id.type=typeForDecl(meaning);
		if(!id.type&&id.sstate!=SemState.error){
			sc.error("invalid forward reference",id.loc);
			id.sstate=SemState.error;
		}
		if(id.type != typeTy()){
			if(auto dsc=isInDataScope(id.meaning.scope_)){
				if(auto decl=sc.getDatDecl()){
					if(decl is dsc.decl){
						auto this_=new Identifier("this");
						this_.loc=id.loc;
						this_.scope_=sc;
						auto fe=new FieldExp(this_,id);
						fe.loc=id.loc;
						return expressionSemantic(fe,sc,ConstResult.no);
					}
				}
			}
		}
		if(auto vd=cast(VarDecl)id.meaning){
			if(cast(TopScope)vd.scope_||vd.vtype==typeTy&&vd.initializer){
				if(!vd.initializer||vd.initializer.sstate!=SemState.completed){
					id.sstate=SemState.error;
					return id;
				}
				return vd.initializer;
			}
		}
		if(id.type&&!id.type.isClassical()){
			if(!constResult){
				if(auto prm=cast(Parameter)meaning){
					if(prm.isConst){
						sc.error(format("use 'dup(%s)' to duplicate 'const' parameter '%s'",prm.name,prm.name), id.loc);
						id.sstate=SemState.error;
					}
				}
			}
			assert(sc.isNestedIn(meaning.scope_));
			for(auto csc=sc;csc !is meaning.scope_;csc=(cast(NestedScope)csc).parent){
				if(auto fsc=cast(FunctionScope)csc){
					if(constResult){
						sc.error("cannot capture variable as constant", id.loc);
						id.sstate=SemState.error;
						break;
					}
					if(fsc.fd&&fsc.fd.context&&fsc.fd.context.vtype==contextTy(true)){
						if(!fsc.fd.ftype) fsc.fd.context.vtype=contextTy(false);
						else{
							assert(!fsc.fd.ftype||fsc.fd.ftype.isClassical());
							sc.error("cannot capture quantum variable in classical function", id.loc);
							id.sstate=SemState.error;
							break;
						}
					}
				}
			}
		}
		return id;
	}
	if(auto fe=cast(FieldExp)expr){
		fe.e=expressionSemantic(fe.e,sc,ConstResult.yes);
		propErr(fe.e,fe);
		if(fe.sstate==SemState.error)
			return fe;
		auto noMember(){
			sc.error(format("no member %s for type %s",fe.f,fe.e.type),fe.loc);
			fe.sstate=SemState.error;
			return fe;
		}
		DatDecl aggrd=null;
		if(auto aggrty=cast(AggregateTy)fe.e.type) aggrd=aggrty.decl;
		else if(auto id=cast(Identifier)fe.e.type) if(auto dat=cast(DatDecl)id.meaning) aggrd=dat;
		Expression arg=null;
		if(auto ce=cast(CallExp)fe.e.type){
			if(auto id=cast(Identifier)ce.e){
				if(auto decl=cast(DatDecl)id.meaning){
					aggrd=decl;
					arg=ce.arg;
				}
			}
		}
		if(aggrd){
			if(aggrd.body_.ascope_){
				auto meaning=aggrd.body_.ascope_.lookupHere(fe.f,false,Lookup.consuming);
				if(!meaning) return noMember();
				fe.f.meaning=meaning;
				fe.f.name=meaning.getName;
				fe.f.scope_=sc;
				fe.f.type=typeForDecl(meaning);
				if(fe.f.type&&aggrd.hasParams){
					auto subst=aggrd.getSubst(arg);
					fe.f.type=fe.f.type.substitute(subst);
				}
				fe.f.sstate=SemState.completed;
				fe.type=fe.f.type;
				if(!fe.type){
					fe.sstate=SemState.error;
					fe.f.sstate=SemState.error;
				}
				return fe;
			}else return noMember();
		}else if(auto r=builtIn(fe,sc)) return r;
		else return noMember();
	}
	if(auto idx=cast(IndexExp)expr){
		bool replaceIndex=false;
		if(sc.indexToReplace){
			auto rid=getIdFromIndex(sc.indexToReplace);
			assert(rid && rid.meaning);
			if(auto cid=getIdFromIndex(idx)){
				if(rid.name==cid.name){
					if(!cid.meaning){
						cid.meaning=rid.meaning;
						replaceIndex=true;
					}
				}
			}
		}
		idx.e=expressionSemantic(idx.e,sc,ConstResult.yes);
		if(auto ft=cast(FunTy)idx.e.type){
			assert(!replaceIndex);
			Expression arg;
			if(!idx.trailingComma&&idx.a.length==1) arg=idx.a[0];
			else arg=new TupleExp(idx.a);
			arg.loc=idx.loc;
			auto ce=new CallExp(idx.e,arg,true,false);
			ce.loc=idx.loc;
			return expr=callSemantic(ce,sc,ConstResult.no);
		}
		if(idx.e.type==typeTy){
			assert(!replaceIndex);
			if(auto tty=typeSemantic(expr,sc))
				return tty;
		}
		propErr(idx.e,idx);
		foreach(ref a;idx.a){
			a=expressionSemantic(a,sc,ConstResult.yes);
			propErr(a,idx);
		}
		if(idx.sstate==SemState.error)
			return idx;
		void check(Expression next){
			if(idx.a.length!=1){
				sc.error(format("only one index required to index type %s",idx.e.type),idx.loc);
				idx.sstate=SemState.error;
			}else{
				if(!isSubtype(idx.a[0].type,ℤt(true))&&!isSubtype(idx.a[0].type,Bool(false))&&!isInt(idx.a[0].type)&&!isUint(idx.a[0].type)){
					sc.error(format("index should be integer, not %s",idx.a[0].type),idx.loc);
					idx.sstate=SemState.error;
				}else{
					idx.type=next;
				}
			}
		}
		if(auto at=cast(ArrayTy)idx.e.type){
			check(at.next);
		}else if(auto vt=cast(VectorTy)idx.e.type){
			check(vt.next);
		}else if(isInt(idx.e.type)||isUint(idx.e.type)){
			check(Bool(idx.e.type.isClassical()));
		}else if(auto tt=cast(TupleTy)idx.e.type){
			if(idx.a.length!=1){
				sc.error(format("only one index required to index type %s",tt),idx.loc);
				idx.sstate=SemState.error;
			}else{
				auto lit=cast(LiteralExp)idx.a[0];
				if(!lit||lit.lit.type!=Tok!"0"){
					sc.error(format("index for type %s should be integer constant",tt),idx.loc); // TODO: allow dynamic indexing if known to be safe?
					idx.sstate=SemState.error;
				}else{
					auto c=ℤ(lit.lit.str);
					if(c<0||c>=tt.types.length){
						sc.error(format("index for type %s is out of bounds [0..%s)",tt,tt.types.length),idx.loc);
						idx.sstate=SemState.error;
					}else{
						idx.type=tt.types[cast(size_t)c.toLong()];
					}
				}
			}
		}else{
			sc.error(format("type %s is not indexable",idx.e.type),idx.loc);
			idx.sstate=SemState.error;
		}
		if(replaceIndex){
			if(idx != sc.indexToReplace){
				sc.error("indices for component replacement must be identical",idx.loc);
				sc.note("replaced component is here",sc.indexToReplace.loc);
				idx.sstate=SemState.error;
			}
			if(constResult){
				sc.error("replaced component must be consumed",idx.loc);
				sc.note("replaced component is here",sc.indexToReplace.loc);
				idx.sstate=SemState.error;
			}
			sc.indexToReplace=null;
		}
		return idx;
	}
	if(auto sl=cast(SliceExp)expr){
		sl.e=expressionSemantic(sl.e,sc,ConstResult.yes);
		propErr(sl.e,sl);
		sl.l=expressionSemantic(sl.l,sc,ConstResult.yes);
		propErr(sl.l,sl);
		sl.r=expressionSemantic(sl.r,sc,ConstResult.yes);
		propErr(sl.r,sl);
		if(sl.sstate==SemState.error)
			return sl;
		if(!isSubtype(sl.l.type,ℤt(true))){
			sc.error(format("lower bound should be classical integer, not %s",sl.l.type),sl.l.loc);
			sl.l.sstate=SemState.error;
		}
		if(!isSubtype(sl.r.type,ℤt(true))){
			sc.error(format("upper bound should be classical integer, not %s",sl.r.type),sl.r.loc);
			sl.r.sstate=SemState.error;
		}
		if(sl.sstate==SemState.error)
			return sl;
		if(auto at=cast(ArrayTy)sl.e.type){
			sl.type=at;
		}else if(auto tt=sl.e.type.isTupleTy){
			auto llit=cast(LiteralExp)sl.l, rlit=cast(LiteralExp)sl.r;
			if(!llit||llit.lit.type!=Tok!"0"){
				sc.error(format("slice lower bound for type %s should be integer constant",cast(Expression)tt),sl.loc);
				sl.sstate=SemState.error;
			}
			if(!rlit||rlit.lit.type!=Tok!"0"){
				sc.error(format("slice upper bound for type %s should be integer constant",cast(Expression)tt),sl.loc);
				sl.sstate=SemState.error;
			}
			if(sl.sstate==SemState.error)
				return sl;
			auto lc=ℤ(llit.lit.str), rc=ℤ(rlit.lit.str);
			if(lc<0){
				sc.error(format("slice lower bound for type %s cannot be negative",tt),sl.loc);
				sl.sstate=SemState.error;
			}
			if(lc>rc){
				sc.error("slice lower bound exceeds slice upper bound",sl.loc);
				sl.sstate=SemState.error;
			}
			if(rc>tt.length){
				sc.error(format("slice upper bound for type %s exceeds %s",tt,tt.length),sl.loc);
				sl.sstate=SemState.error;
			}
			sl.type=tt[cast(size_t)lc..cast(size_t)rc];
		}else{
			sc.error(format("type %s is not sliceable",sl.e.type),sl.loc);
			sl.sstate=SemState.error;
		}
		return sl;
	}
	if(cast(CommaExp)expr){
		sc.error("nested comma expressions are disallowed",expr.loc);
		expr.sstate=SemState.error;
		return expr;
	}
	if(auto tpl=cast(TupleExp)expr){
		foreach(ref exp;tpl.e){
			exp=expressionSemantic(exp,sc,constResult);
			propErr(exp,tpl);
		}
		if(tpl.sstate!=SemState.error){
			tpl.type=tupleTy(tpl.e.map!(e=>e.type).array);
		}
		return tpl;
	}
	if(auto arr=cast(ArrayExp)expr){
		Expression t; bool tok=true;
		foreach(i,ref exp;arr.e){
			exp=expressionSemantic(exp,sc,constResult);
			propErr(exp,arr);
			t = joinTypes(t, exp.type);
			if(!t&&tok){
				Expression texp;
				foreach(j,oexp;arr.e[0..i]){
					if(!joinTypes(oexp, exp)){
						texp=oexp;
						break;
					}
				}
				if(texp){
					sc.error(format("incompatible types %s and %s in array literal",t,exp.type),texp.loc);
					sc.note("incompatible entry",exp.loc);
				}
				arr.sstate=SemState.error;
				tok=false;
			}
		}
		if(arr.e.length && t){
			if(arr.e[0].type) arr.type=arrayTy(t);
		}else arr.type=arrayTy(ℝ(true)); // TODO: type inference?
		return arr;
	}
	if(auto tae=cast(TypeAnnotationExp)expr){
		tae.e=expressionSemantic(tae.e,sc,constResult);
		tae.type=typeSemantic(tae.t,sc);
		propErr(tae.e,tae);
		propErr(tae.t,tae);
		if(!tae.type||tae.sstate==SemState.error)
			return tae;
		if(auto arr=cast(ArrayExp)tae.e){
			if(!arr.e.length)
				if(auto aty=cast(ArrayTy)tae.type)
					arr.type=aty;
		}
		if(auto ce=cast(CallExp)tae.e)
			if(auto id=cast(Identifier)ce.e){
				if(id.name=="sampleFrom"||id.name=="readCSV"&&tae.type==arrayTy(arrayTy(ℝ(true))))
					ce.type=tae.type;
			}
		bool typeExplicitConversion(Expression from,Expression to){
			if(isSubtype(from,to)) return true;
			if(isSubtype(from,ℤt(false))&&(isUint(to)||isInt(to))&&from.isClassical()>=to.isClassical())
				return true;
			if(isUint(from)&&isSubtype(ℕt(from.isClassical()),to))
				return true;
			if(isInt(from)&&isSubtype(ℤt(from.isClassical()),to))
				return true;
			if((isRat(from)||isFloat(from))&&isSubtype(ℚt(from.isClassical()),to))
				return true;
			auto ce1=cast(CallExp)from;
			if(ce1&&(isInt(ce1)||isUint(ce1))&&(isSubtype(vectorTy(Bool(ce1.isClassical()),ce1.arg),to)||isSubtype(arrayTy(Bool(ce1.isClassical())),to)))
				return true;
			auto ce2=cast(CallExp)to;
			if(ce2&&(isInt(ce2)||isUint(ce2))&&(isSubtype(from,vectorTy(Bool(ce2.isClassical()),ce2.arg))||isSubtype(from,arrayTy(Bool(ce2.isClassical())))))
				return true;
			auto tpl1=cast(TupleTy)from, tpl2=cast(TupleTy)to;
			if(tpl1&&tpl2&&tpl1.types.length==tpl2.types.length&&zip(tpl1.types,tpl2.types).all!(x=>typeExplicitConversion(x.expand)))
				return true;
			auto arr1=cast(ArrayTy)from, arr2=cast(ArrayTy)to;
			if(arr1&&arr2&&typeExplicitConversion(arr1.next,arr2.next))
				return true;
			auto vec1=cast(VectorTy)from, vec2=cast(VectorTy)to;
			if(vec1&&vec2&&vec1.num==vec2.num&&typeExplicitConversion(vec1.next,vec2.next))
				return true;
			if(arr1&&vec2&&typeExplicitConversion(arr1.next,vec2.next))
				return true;
			if(vec1&&arr2&&typeExplicitConversion(vec1.next,arr2.next))
				return true;
			return false;
		}
		bool explicitConversion(Expression expr,Expression type){
			if(typeExplicitConversion(expr.type,type)) return true;
			if(auto lit=cast(LiteralExp)expr){
				if(isSubtype(expr.type,ℝ(false))&&isSubtype(ℚt(true),type))
					return true;
				if(isSubtype(expr.type,ℝ(false))&&(isRat(type)||isFloat(type)))
					return true;
				if(cast(BoolTy)type&&lit.lit.type==Tok!"0"){
					auto val=ℤ(lit.lit.str);
					if(val==0||val==1) return true;
				}
			}
			if(auto tpl1=cast(TupleExp)expr){
				if(auto tpl2=type.isTupleTy()){
					return tpl1.e.length==tpl2.length&&iota(tpl1.e.length).all!(i=>explicitConversion(tpl1.e[i],tpl2[i]));
				}
			}
			return false;
		}
		if(!explicitConversion(tae.e,tae.type)){
			sc.error(format("type is %s, not %s",tae.e.type,tae.type),tae.loc);
			tae.sstate=SemState.error;
		}
		return tae;
	}

	Expression handleUnary(alias determineType)(string name,Expression e,ref Expression e1){
		e1=expressionSemantic(e1,sc,ConstResult.yes);
		propErr(e1,e);
		if(e.sstate==SemState.error)
			return e;
		e.type=determineType(e1.type);
		if(!e.type){
			sc.error(format("incompatible type %s for %s",e1.type,name),e.loc);
			e.sstate=SemState.error;
		}
		return e;
	}

	Expression handleBinary(alias determineType)(string name,Expression e,ref Expression e1,ref Expression e2){
		e1=expressionSemantic(e1,sc,ConstResult.yes);
		e2=expressionSemantic(e2,sc,ConstResult.yes);
		propErr(e1,e);
		propErr(e2,e);
		if(e.sstate==SemState.error)
			return e;
		if(e1.type==typeTy&&name=="power"){
			/+if(auto le=cast(LiteralExp)e2){
				if(le.lit.type==Tok!"0"){
					if(!le.lit.str.canFind(".")){
						auto n=ℤ(le.lit.str);
						if(0<=n&&n<long.max)
							return tupleTy(e1.repeat(cast(size_t)n.toLong()).array);
					}
				}
			}
			sc.error("expected non-negative integer constant",e2.loc);
			e.sstate=SemState.error;+/
			if(!isSubtype(e2.type,ℕt(true))){
				sc.error(format("vector length should be of type !ℕ, not %s",e2), e2.loc);
				e.sstate=SemState.error;
			}else return vectorTy(e1,e2);
		}else{
			e.type = determineType(e1.type,e2.type);
			if(!e.type){
				sc.error(format("incompatible types %s and %s for %s",e1.type,e2.type,name),e.loc);
				e.sstate=SemState.error;
			}
		}
		return e;
	}
	if(auto ae=cast(AddExp)expr) return expr=handleBinary!(arithmeticType!false)("addition",ae,ae.e1,ae.e2);
	if(auto ae=cast(SubExp)expr) return expr=handleBinary!subtractionType("subtraction",ae,ae.e1,ae.e2);
	if(auto ae=cast(NSubExp)expr) return expr=handleBinary!nSubType("natural subtraction",ae,ae.e1,ae.e2);
	if(auto ae=cast(MulExp)expr) return expr=handleBinary!(arithmeticType!true)("multiplication",ae,ae.e1,ae.e2);
	if(auto ae=cast(DivExp)expr) return expr=handleBinary!divisionType("division",ae,ae.e1,ae.e2);
	if(auto ae=cast(IDivExp)expr) return expr=handleBinary!iDivType("integer division",ae,ae.e1,ae.e2);
	if(auto ae=cast(ModExp)expr) return expr=handleBinary!moduloType("modulo",ae,ae.e1,ae.e2);
	if(auto ae=cast(PowExp)expr) return expr=handleBinary!powerType("power",ae,ae.e1,ae.e2);
	if(auto ae=cast(BitOrExp)expr) return expr=handleBinary!(arithmeticType!true)("bitwise or",ae,ae.e1,ae.e2);
	if(auto ae=cast(BitXorExp)expr) return expr=handleBinary!(arithmeticType!true)("bitwise xor",ae,ae.e1,ae.e2);
	if(auto ae=cast(BitAndExp)expr) return expr=handleBinary!(arithmeticType!true)("bitwise and",ae,ae.e1,ae.e2);
	if(auto ae=cast(UMinusExp)expr) return expr=handleUnary!minusBitNotType("minus",ae,ae.e);
	if(auto ae=cast(UNotExp)expr){
		ae.e=expressionSemantic(ae.e,sc,ConstResult.yes);
		if(ae.e.type==typeTy){
			if(auto ty=typeSemantic(ae.e,sc)){
				if(ty.sstate==SemState.completed){
					if(auto r=ty.getClassical()){
						return expr=typeSemantic(r,sc);
					}else{
						// TODO: have explicit ClassicalTy
						sc.error(format("cannot make type %s classical",ae.e),ae.loc);
						ae.sstate=SemState.error;
						return ae;
					}
				}
			}
		}
		return expr=handleUnary!notType("not",ae,ae.e);
	}
	if(auto ae=cast(UBitNotExp)expr) return expr=handleUnary!minusBitNotType("bitwise not",ae,ae.e);
	if(auto ae=cast(UnaryExp!(Tok!"const"))expr){
		sc.error("invalid 'const' annotation", ae.loc);
		ae.sstate=SemState.error;
		return ae;
	}
	if(auto ae=cast(AndExp)expr) return expr=handleBinary!logicType("conjunction",ae,ae.e1,ae.e2);
	if(auto ae=cast(OrExp)expr) return expr=handleBinary!logicType("disjunction",ae,ae.e1,ae.e2);
	if(auto ae=cast(LtExp)expr) return expr=handleBinary!cmpType("'<'",ae,ae.e1,ae.e2);
	if(auto ae=cast(LeExp)expr) return expr=handleBinary!cmpType("'≤'",ae,ae.e1,ae.e2);
	if(auto ae=cast(GtExp)expr) return expr=handleBinary!cmpType("'>'",ae,ae.e1,ae.e2);
	if(auto ae=cast(GeExp)expr) return expr=handleBinary!cmpType("'≥'",ae,ae.e1,ae.e2);
	if(auto ae=cast(EqExp)expr) return expr=handleBinary!cmpType("'='",ae,ae.e1,ae.e2);
	if(auto ae=cast(NeqExp)expr) return expr=handleBinary!cmpType("'≠'",ae,ae.e1,ae.e2);

	if(auto ce=cast(CatExp)expr){
		ce.e1=expressionSemantic(ce.e1,sc,ConstResult.yes);
		ce.e2=expressionSemantic(ce.e2,sc,ConstResult.yes);
		propErr(ce.e1,ce);
		propErr(ce.e2,ce);
		if(ce.sstate==SemState.error)
			return ce;
		if(cast(ArrayTy)ce.e1.type && ce.e1.type == ce.e2.type){
			ce.type=ce.e1.type;
		}else{
			sc.error(format("incompatible types %s and %s for ~",ce.e1.type,ce.e2.type),ce.loc);
			ce.sstate=SemState.error;
		}
		return ce;
	}

	if(auto pr=cast(BinaryExp!(Tok!"×"))expr){
		// TODO: allow nested declarations
		expr.type=typeTy();
		auto t1=typeSemantic(pr.e1,sc);
		auto t2=typeSemantic(pr.e2,sc);
		if(!t1||!t2){
			expr.sstate=SemState.error;
			return expr;
		}
		auto l=t1.isTupleTy(),r=t2.isTupleTy();
		if(l && r && !pr.e1.brackets && !pr.e2.brackets)
			return tupleTy(chain(iota(l.length).map!(i=>l[i]),iota(r.length).map!(i=>r[i])).array);
		if(l&&!pr.e1.brackets) return tupleTy(chain(iota(l.length).map!(i=>l[i]),only(t2)).array);
		if(r&&!pr.e2.brackets) return tupleTy(chain(only(t1),iota(r.length).map!(i=>r[i])).array);
		return tupleTy([t1,t2]);
	}
	if(auto ex=cast(BinaryExp!(Tok!"→"))expr){
		expr.type=typeTy();
		Q!(bool[],Expression) getConstAndType(Expression e){
			if(auto pr=cast(BinaryExp!(Tok!"×"))e){
				auto t1=getConstAndType(pr.e1);
				auto t2=getConstAndType(pr.e2);
				if(!t1[1]||!t2[1]){
					e.sstate=SemState.error;
					return q((bool[]).init,Expression.init);
				}
				auto l=t1[1].isTupleTy,r=t2[1].isTupleTy;
				if(l && r && !pr.e1.brackets && !pr.e2.brackets)
					return q(t1[0]~t2[0],cast(Expression)tupleTy(chain(iota(l.length).map!(i=>l[i]),iota(r.length).map!(i=>r[i])).array));
				if(l&&!pr.e1.brackets) return q(t1[0]~t2[0],cast(Expression)tupleTy(chain(iota(l.length).map!(i=>l[i]),only(t2[1])).array));
				if(r&&!pr.e2.brackets) return q(t1[0]~t2[0],cast(Expression)tupleTy(chain(only(t1[1]),iota(r.length).map!(i=>r[i])).array));
				return q(t1[0]~t2[0],cast(Expression)tupleTy([t1[1],t2[1]]));
			}else if(auto ce=cast(UnaryExp!(Tok!"const"))e){
				return q([true],typeSemantic(ce.e,sc));
			}else{
				auto ty=typeSemantic(e,sc);
				return q([ty.impliesConst()||ex.annotation>=Annotation.lifted],ty);
			}
		}
		auto t1=getConstAndType(ex.e1);
		auto t2=typeSemantic(ex.e2,sc);
		if(!t1[1]||!t2){
			expr.sstate=SemState.error;
			return expr;
		}
		return expr=funTy(t1[0],t1[1],t2,false,!!t1[1].isTupleTy()&&t1[0].length!=1,ex.annotation,false);
	}
	if(auto fa=cast(RawProductTy)expr){
		expr.type=typeTy();
		auto fsc=new RawProductScope(sc,fa.annotation);
		scope(exit) fsc.forceClose();
		declareParameters(fa,fa.isSquare,fa.params,fsc); // parameter variables
		auto cod=typeSemantic(fa.cod,fsc);
		propErr(fa.cod,fa);
		if(fa.sstate==SemState.error) return fa;
		auto const_=fa.params.map!(p=>p.isConst).array;
		auto names=fa.params.map!(p=>p.getName).array;
		auto types=fa.params.map!(p=>p.vtype).array;
		assert(fa.isTuple||types.length==1);
		auto dom=fa.isTuple?tupleTy(types):types[0];
		return expr=productTy(const_,names,dom,cod,fa.isSquare,fa.isTuple,fa.annotation,false);
	}
	if(auto ite=cast(IteExp)expr){
		ite.cond=expressionSemantic(ite.cond,sc,ConstResult.yes);
		sc.pushConsumed();
		if(ite.then.s.length!=1||ite.othw&&ite.othw.s.length!=1){
			sc.error("branches of if expression must be single expressions;",ite.loc);
			ite.sstate=SemState.error;
			return ite;
		}
		Expression branchSemantic(Expression branch){
			if(auto ae=cast(AssertExp)branch){
				branch=statementSemantic(branch,sc);
				if(auto lit=cast(LiteralExp)ae.e)
					if(lit.lit.type==Tok!"0" && lit.lit.str=="0")
						branch.type=null;
			}else branch=expressionSemantic(branch,sc,ConstResult.no);
			return branch;
		}
		ite.then.s[0]=branchSemantic(ite.then.s[0]);
		propErr(ite.then.s[0],ite.then);
		if(!ite.othw){
			sc.error("missing else for if expression",ite.loc);
			ite.sstate=SemState.error;
			return ite;
		}
		ite.othw.s[0]=branchSemantic(ite.othw.s[0]);
		propErr(ite.othw.s[0],ite.othw);
		propErr(ite.cond,ite);
		propErr(ite.then,ite);
		propErr(ite.othw,ite);
		if(ite.sstate==SemState.error)
			return ite;
		if(!ite.then.s[0].type) ite.then.s[0].type = ite.othw.s[0].type;
		if(!ite.othw.s[0].type) ite.othw.s[0].type = ite.then.s[0].type;
		auto t1=ite.then.s[0].type;
		auto t2=ite.othw.s[0].type;
		ite.type=joinTypes(t1,t2);
		if(t1 && t2 && !ite.type){
			sc.error(format("incompatible types %s and %s for branches of if expression",t1,t2),ite.loc);
			ite.sstate=SemState.error;
		}
		return ite;
	}
	if(auto lit=cast(LiteralExp)expr){
		switch(lit.lit.type){
		case Tok!"0",Tok!".0":
			if(!expr.type)
				expr.type=lit.lit.str.canFind(".")?ℝ(true):lit.lit.str.canFind("-")?ℤt(true):ℕt(true); // TODO: type inference
			return expr;
		case Tok!"``":
			expr.type=stringTy(true);
			return expr;
		default: break; // TODO
		}
	}
	if(expr.kind=="expression") sc.error("unsupported",expr.loc);
	else sc.error(expr.kind~" cannot appear within an expression",expr.loc);
	expr.sstate=SemState.error;
	return expr;
}
bool setFtype(FunctionDef fd){
	bool[] pc;
	string[] pn;
	Expression[] pty;
	foreach(p;fd.params){
		if(!p.vtype){
			assert(fd.sstate==SemState.error);
			return false;
		}
		pc~=p.isConst;
		pn~=p.getName;
		pty~=p.vtype;
	}
	assert(fd.isTuple||pty.length==1);
	auto pt=fd.isTuple?tupleTy(pty):pty[0];
	if(fd.ret){
		if(!fd.ftype){
			fd.ftype=productTy(pc,pn,pt,fd.ret,fd.isSquare,fd.isTuple,fd.annotation,!fd.context||fd.context.vtype==contextTy(true));
			assert(fd.retNames==[]);
		}
		if(!fd.retNames) fd.retNames = new string[](fd.numReturns);
		assert(fd.fscope_||fd.sstate==SemState.error);
	}
	return true;
}
FunctionDef functionDefSemantic(FunctionDef fd,Scope sc){
	if(fd.sstate==SemState.completed) return fd;
	if(!fd.fscope_) fd=cast(FunctionDef)presemantic(fd,sc); // TODO: why does checking for fd.scope_ not work? (test3.hql)
	auto fsc=fd.fscope_;
	++fd.semanticDepth;
	assert(!!fsc,text(fd));
	assert(fsc.allowsLinear());
	auto bdy=fd.body_?compoundExpSemantic(fd.body_,fsc):null;
	scope(exit){
		fsc.pushConsumed();
		if(fd.ret&&fd.ret.sstate==SemState.completed){
			foreach(id;fd.ret.freeIdentifiers){
				assert(!!id.meaning);
				auto allowMerge=fsc.allowMerge;
				fsc.allowMerge=false;
				auto meaning=fsc.lookup(id,false,true,Lookup.probing);
				fsc.allowMerge=allowMerge;
				assert(!meaning||!meaning.isLinear);
				if(meaning !is id.meaning){
					fsc.error(format("variable '%s' in function return type does not appear in function scope", id.name), fd.loc);
					fd.sstate=SemState.error;
				}
			}
		}
		if(bdy){
			if(--fd.semanticDepth==0&&(fsc.merge(false,bdy.blscope_)||fsc.close())) fd.sstate=SemState.error;
		}else{
			fsc.forceClose();
		}
	}
	fd.body_=bdy;
	fd.type=unit;
	if(bdy){
		propErr(bdy,fd);
		if(!definitelyReturns(fd)){
			if(!fd.ret || fd.ret == unit){
				auto tpl=new TupleExp([]);
				tpl.loc=fd.loc;
				auto rete=new ReturnExp(tpl);
				rete.loc=fd.loc;
				fd.body_.s~=returnExpSemantic(rete,fd.body_.blscope_);
			}else{
				sc.error("control flow might reach end of function (add return or assert(false) statement)",fd.loc);
				fd.sstate=SemState.error;
			}
		}else if(!fd.ret) fd.ret=unit;
	}else if(!fd.ret) fd.ret=unit;
	setFtype(fd);
	foreach(ref n;fd.retNames){
		if(n is null) n="r";
		else n=n.stripRight('\'');
	}
	void[0][string] vars;
	foreach(p;fd.params) vars[p.getName]=[];
	int[string] counts1,counts2;
	foreach(n;fd.retNames)
		++counts1[n];
	foreach(ref n;fd.retNames){
		if(counts1[n]>1)
			n~=lowNum(++counts2[n]);
		while(n in vars) n~="'";
		vars[n]=[];
	}
	if(fd.sstate!=SemState.error)
		fd.sstate=SemState.completed;
	return fd;
}

DatDecl datDeclSemantic(DatDecl dat,Scope sc){
	bool success=true;
	if(!dat.dscope_) presemantic(dat,sc);
	auto bdy=compoundDeclSemantic(dat.body_,dat.dscope_);
	assert(!!bdy);
	dat.body_=bdy;
	dat.type=unit;
	return dat;
}

Expression determineType(ref Expression e,Scope sc){
	/+if(auto le=cast(LambdaExp)e){
		assert(!!le.fd);
		if(!le.fd.scope_){
			le.fd.scope_=sc;
			le.fd=cast(FunctionDef)presemantic(le.fd,sc);
			assert(!!le.fd);
		}
		if(auto ty=le.fd.ftype)
			return ty;
	}+/
	e=expressionSemantic(e,sc,ConstResult.no);
	return e.type;
}

ReturnExp returnExpSemantic(ReturnExp ret,Scope sc){
	if(ret.sstate==SemState.completed) return ret;
	auto fd=sc.getFunction();
	if(!fd){
		sc.error("return statement must be within function",ret.loc);
		ret.sstate=SemState.error;
		return ret;
	}
	auto ty=determineType(ret.e,sc);
	if(!fd.rret && !fd.ret) fd.ret=ty;
	setFtype(fd);
	if(ret.e.sstate!=SemState.completed)
		ret.e=expressionSemantic(ret.e,sc,ConstResult.no);
	if(cast(CommaExp)ret.e){
		sc.error("use parentheses for multiple return values",ret.e.loc);
		ret.sstate=SemState.error;
	}
	propErr(ret.e,ret);
	if(ret.sstate==SemState.error)
		return ret;
	if(!isSubtype(ret.e.type,fd.ret)){
		sc.error(format("%s is incompatible with return type %s",ret.e.type,fd.ret),ret.e.loc);
		ret.sstate=SemState.error;
		return ret;
	}
	ret.type=unit;
	Expression[] returns;
	if(auto tpl=cast(TupleExp)ret.e) returns=tpl.e;
	else returns = [ret.e];
	static string getName(Expression e){
		string candidate(Expression e,bool allowNum=false){
			if(auto id=cast(Identifier)e) return id.name;
			if(auto fe=cast(FieldExp)e) return fe.f.name;
			if(auto ie=cast(IndexExp)e){
				auto idx=candidate(ie.a[0],true);
				if(!idx) idx="i";
				auto low=toLow(idx);
				if(!low) low="_"~idx;
				auto a=candidate(ie.e);
				if(!a) return null;
				return a~low;
			}
			if(allowNum){
				if(auto le=cast(LiteralExp)e){
					if(le.lit.type==Tok!"0")
						return le.lit.str;
				}
			}
			return null;
		}
		auto r=candidate(e);
		if(util.among(r.stripRight('\''),"delta","sum","abs","log","lim","val","⊥","case","e","π")) return null;
		return r;
	}
	if(returns.length==fd.retNames.length){
		foreach(i,e;returns)
			if(auto n=getName(e)) fd.retNames[i]=n;
	}else if(returns.length==1){
		if(auto name=getName(returns[0]))
			foreach(ref n;fd.retNames) n=name;
	}
	return ret;
}


Expression typeSemantic(Expression expr,Scope sc)in{assert(!!expr&&!!sc);}body{
	if(expr.type==typeTy) return expr;
	if(auto lit=cast(LiteralExp)expr){
		lit.type=typeTy;
		if(lit.lit.type==Tok!"0"){
			if(lit.lit.str=="1")
				return unit;
		}
	}
	auto at=cast(IndexExp)expr;
	if(at&&at.a==[]){
		expr.type=typeTy;
		auto next=typeSemantic(at.e,sc);
		propErr(at.e,expr);
		if(!next) return null;
		return arrayTy(next);
	}
	auto e=expressionSemantic(expr,sc,ConstResult.no);
	if(!e) return null;
	if(e.type==typeTy) return e;
	if(expr.sstate!=SemState.error){
		auto id=cast(Identifier)expr;
		if(id&&id.meaning){
			auto decl=id.meaning;
			sc.error(format("%s %s is not a type",decl.kind,decl.name),id.loc);
			sc.note("declared here",decl.loc);
		}else sc.error("not a type",expr.loc);
		expr.sstate=SemState.error;
	}
	return null;
 }

Expression typeForDecl(Declaration decl){
	if(auto dat=cast(DatDecl)decl){
		if(!dat.dtype&&dat.scope_) dat=cast(DatDecl)presemantic(dat,dat.scope_);
		assert(cast(AggregateTy)dat.dtype);
		if(!dat.hasParams) return typeTy;
		foreach(p;dat.params) if(!p.vtype) return unit; // TODO: ok?
		assert(dat.isTuple||dat.params.length==1);
		auto pt=dat.isTuple?tupleTy(dat.params.map!(p=>p.vtype).array):dat.params[0].vtype;
		return productTy(dat.params.map!(p=>p.isConst).array,dat.params.map!(p=>p.getName).array,pt,typeTy,true,dat.isTuple,Annotation.lifted,true);
	}
	if(auto vd=cast(VarDecl)decl){
		return vd.vtype;
	}
	if(auto fd=cast(FunctionDef)decl){
		if(!fd.ftype&&fd.scope_) fd=functionDefSemantic(fd,fd.scope_);
		assert(!!fd);
		return fd.ftype;
	}
	return unit; // TODO
}

bool definitelyReturns(FunctionDef fd){
	bool doIt(Expression e){
		if(auto ret=cast(ReturnExp)e)
			return true;
		bool isZero(Expression e){
			if(auto tae=cast(TypeAnnotationExp)e)
				return isZero(tae.e);
			if(auto le=cast(LiteralExp)e)
				if(le.lit.type==Tok!"0")
					if(le.lit.str=="0")
						return true;
			return false;
		}
		alias isFalse=isZero;
		bool isTrue(Expression e){
			if(auto le=cast(LiteralExp)e)
				if(le.lit.type==Tok!"0")
					return le.lit.str!="0";
			return false;
		}
		bool isPositive(Expression e){
			if(isZero(e)) return false;
			if(auto le=cast(LiteralExp)e)
				if(le.lit.type==Tok!"0")
					return le.lit.str[0]!='-';
			return false;
		}
		if(auto ae=cast(AssertExp)e)
			return isFalse(ae.e);
		if(auto oe=cast(ObserveExp)e)
			return isFalse(oe.e);
		if(auto ce=cast(CompoundExp)e)
			return ce.s.any!(x=>doIt(x));
		if(auto ite=cast(IteExp)e)
			return doIt(ite.then) && doIt(ite.othw);
		if(auto fe=cast(ForExp)e){
			auto lle=cast(LiteralExp)fe.left;
			auto rle=cast(LiteralExp)fe.right;
			if(lle && rle && lle.lit.type==Tok!"0" && rle.lit.type==Tok!"0"){
				ℤ l=ℤ(lle.lit.str), r=ℤ(rle.lit.str);
				l+=cast(long)fe.leftExclusive;
				r-=cast(long)fe.rightExclusive;
				return l<=r && doIt(fe.bdy);
			}
			return false;
		}
		if(auto we=cast(WhileExp)e)
			return isTrue(we.cond) && doIt(we.bdy);
		if(auto re=cast(RepeatExp)e)
			return isPositive(re.num);
		return false;
	}
	return doIt(fd.body_);
}

/+
import dexpr;
struct VarMapping{
	DNVar orig;
	DNVar tmp;
}
struct SampleFromInfo{
	bool error;
	VarMapping[] retVars;
	DNVar[] paramVars;
	DExpr newDist;
}

import distrib; // TODO: separate concerns properly, move the relevant parts back to analysis.d
SampleFromInfo analyzeSampleFrom(CallExp ce,ErrorHandler err,Distribution dist=null){ // TODO: support for non-real-valued distributions
	Expression[] args;
	if(auto tpl=cast(TupleExp)ce.arg) args=tpl.e;
	else args=[ce.arg];
	if(args.length==0){
		err.error("expected arguments to sampleFrom",ce.loc);
		return SampleFromInfo(true);
	}
	auto literal=cast(LiteralExp)args[0];
	if(!literal||literal.lit.type!=Tok!"``"){
		err.error("first argument to sampleFrom must be string literal",args[0].loc);
		return SampleFromInfo(true);
	}
	VarMapping[] retVars;
	DNVar[] paramVars;
	DExpr newDist;
	import hashtable;
	HSet!(string,(a,b)=>a==b,a=>typeid(string).getHash(&a)) names;
	try{
		import dparse;
		auto parser=DParser(literal.lit.str);
		parser.skipWhitespace();
		parser.expect('(');
		for(bool seen=false;parser.cur()!=')';){
			parser.skipWhitespace();
			if(parser.cur()==';'){
				seen=true;
				parser.next();
				continue;
			}
			auto orig=cast(DNVar)parser.parseDVar();
			if(!orig) throw new Exception("TODO");
			if(orig.name in names){
				err.error(text("multiple variables of name \"",orig.name,"\""),args[0].loc);
				return SampleFromInfo(true);
			}
			if(!seen){
				auto tmp=dist?dist.getTmpVar("__tmp"~orig.name):null; // TODO: this is a hack
				retVars~=VarMapping(orig,tmp);
			}else paramVars~=orig;
			parser.skipWhitespace();
			if(!";)"[seen..$].canFind(parser.cur())) parser.expect(',');
		}
		parser.next();
		parser.skipWhitespace();
		if(parser.cur()=='⇒') parser.next();
		else{ parser.expect('='); parser.expect('>'); }
		parser.skipWhitespace();
		newDist=parser.parseDExpr();
	}catch(Exception e){
		err.error(e.msg,args[0].loc);
		return SampleFromInfo(true);
	}
	if(dist){
		foreach(var;retVars){
			if(!newDist.hasFreeVar(var.orig)){
				err.error(text("pdf must depend on variable ",var.orig.name,")"),args[0].loc);
				return SampleFromInfo(true);
			}
		}
		newDist=newDist.substituteAll(retVars.map!(x=>cast(DVar)x.orig).array,retVars.map!(x=>cast(DExpr)x.tmp).array);
	}
	if(args.length!=1+paramVars.length){
		err.error(text("expected ",paramVars.length," additional arguments to sampleFrom"),ce.loc);
		return SampleFromInfo(true);
	}
	return SampleFromInfo(false,retVars,paramVars,newDist);
}

Expression handleSampleFrom(CallExp ce,Scope sc){
	auto info=analyzeSampleFrom(ce,sc.handler);
	if(info.error){
		ce.sstate=SemState.error;
	}else{
		 // TODO: this special casing is not very nice:
		ce.type=info.retVars.length==1?ℝ(true):tupleTy((cast(Expression)ℝ(true)).repeat(info.retVars.length).array);
	}
	return ce;
}
+/
Expression handleQuantumPrimitive(CallExp ce,Scope sc){
	Expression[] args;
	if(auto tpl=cast(TupleExp)ce.arg) args=tpl.e;
	else args=[ce.arg];
	if(args.length==0){
		sc.error("expected argument to quantumPrimitive",ce.loc);
		ce.sstate=SemState.error;
		return ce;
	}
	auto literal=cast(LiteralExp)args[0];
	if(!literal||literal.lit.type!=Tok!"``"){
		sc.error("first argument to quantumPrimitive must be string literal",args[0].loc);
		ce.sstate=SemState.error;
		return ce;
	}
	switch(literal.lit.str){
		case "dup":
			ce.type = productTy([true],["`τ"],typeTy,funTy([true],varTy("`τ",typeTy),varTy("`τ",typeTy),false,false,Annotation.lifted,true),true,false,Annotation.lifted,true);
			break;
		case "array":
			ce.type = productTy([true],["`τ"],typeTy,funTy([true,true],tupleTy([ℕt(true),varTy("`τ",typeTy)]),arrayTy(varTy("`τ",typeTy)),false,true,Annotation.lifted,true),true,false,Annotation.lifted,true);
			break;
		case "vector":
			ce.type = productTy([true],["`τ"],typeTy,productTy([true,true],["`n","`x"],tupleTy([ℕt(true),varTy("`τ",typeTy)]),vectorTy(varTy("`τ",typeTy),varTy("`n",ℕt(true))),false,true,Annotation.lifted,true),true,false,Annotation.lifted,true);
			break;
		case "reverse":
			ce.type = productTy([true,true,true],["`τ","`χ","`φ"],tupleTy([typeTy,typeTy,typeTy]),funTy([true],funTy([false,true],tupleTy([varTy("`τ",typeTy),varTy("`χ",typeTy)]),varTy("`φ",typeTy),false,true,Annotation.mfree,true),funTy([false,true],tupleTy([varTy("`φ",typeTy),varTy("`χ",typeTy)]),varTy("`τ",typeTy),false,true,Annotation.mfree,true),false,false,Annotation.lifted,true),true,true,Annotation.lifted,true);
			break;
		case "M":
			ce.type = productTy([true],["`τ"],typeTy,funTy([false],varTy("`τ",typeTy),varTy("`τ",typeTy,true),false,false,Annotation.none,true),true,false,Annotation.lifted,true);
			break;
		case "H","X","Y","Z":
			ce.type = funTy([false],Bool(false),Bool(false),false,false,Annotation.mfree,true);
			break;
		case "P":
			ce.type = funTy([true],ℝ(true),unit,false,false,Annotation.mfree,true);
			break;
		case "rX","rY","rZ":
			ce.type = funTy([false,true],tupleTy([Bool(false),ℝ(true)]),Bool(false),false,true,Annotation.mfree,true);
			break;
		default:
			sc.error(format("unknown quantum primitive %s",literal.lit.str),literal.loc);
			ce.sstate=SemState.error;
			break;
	}
	return ce;
}

Expression handleQuery(CallExp ce,Scope sc){
	Expression[] args;
	if(auto tpl=cast(TupleExp)ce.arg) args=tpl.e;
	else args=[ce.arg];
	if(args.length==0){
		sc.error("expected argument to __query",ce.loc);
		ce.sstate=SemState.error;
		return ce;
	}
	auto literal=cast(LiteralExp)args[0];
	if(!literal||literal.lit.type!=Tok!"``"){
		sc.error("first argument to __query must be string literal",args[0].loc);
		ce.sstate=SemState.error;
		return ce;
	}
	switch(literal.lit.str){
		case "dep":
			if(args.length!=2||!cast(Identifier)args[1]){
				sc.error("expected single variable as argument to 'dep' query", ce.loc);
				ce.sstate=SemState.error;
				break;
			}else{
				args[1]=expressionSemantic(args[1],sc,ConstResult.yes);
				auto dep="{}";
				if(auto id=cast(Identifier)args[1]){
					if(id.sstate==SemState.completed){
						auto dependency=sc.getDependency(id);
						if(dependency.isTop) dep="⊤";
						else dep=dependency.dependencies.to!string;
					}
				}
				Token tok;
				tok.type=Tok!"``";
				tok.str=dep;
				auto nlit=New!LiteralExp(tok);
				nlit.loc=ce.loc;
				nlit.type=stringTy(true);
				nlit.sstate=SemState.completed;
				return nlit;
			}
		default:
			sc.error(format("unknown query '%s'",literal.lit.str),literal.loc);
			ce.sstate=SemState.error;
			break;
	}
	return ce;
}
